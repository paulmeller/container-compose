//
//  Engine.swift
//  container-compose
//

import ComposeCore
import Foundation

/// Executes a `Plan` against a runtime, reconciling rather than recreating.
///
/// This is the only layer that performs I/O. It never prints — it emits
/// `EngineEvent`s and lets every consumer (CLI, GUI, test) decide what to do
/// with them.
public actor Engine {
    // `internal` (the default), not `private`: EngineLifecycle.swift extends
    // this actor from a separate file and needs to reach the adapter too.
    // Still not `public` — nothing outside this module should call the
    // adapter directly and bypass Engine's orchestration.
    let adapter: RuntimeAdapter

    /// Volumes this run created and has not yet seeded. Seeding happens when
    /// the first container that mounts one is created — matching Docker, and
    /// necessarily so: only then is the image guaranteed present to copy from.
    /// Actor-isolated, which is what makes it safe for a wave's concurrent
    /// services to consult it without seeding the same volume twice.
    private var volumesAwaitingSeed: Set<String> = []

    public init(adapter: RuntimeAdapter) {
        self.adapter = adapter
    }

    /// Reconciles `plan` against observed reality, executes the result, and
    /// returns the full event stream as an array.
    ///
    /// - Parameter onEvent: Called synchronously as each event is produced —
    ///   not after the operation completes. This is what makes the protocol
    ///   layer's NDJSON output real progress rather than a batch dump at the
    ///   end: a slow image pull for one service does not hold up the
    ///   already-available progress of another running concurrently in the
    ///   same wave. The returned array remains the complete, ordered record —
    ///   existing callers that only need the final result are unaffected.
    @discardableResult
    public func up(_ plan: Plan, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        emit(.planned(services: plan.services.map(\.name), waves: plan.waves))

        // Networks come before the first wave, not alongside it: a container
        // referencing a network that does not exist fails at create time, and
        // every service in the project would fail the same way for the same
        // reason. Failing once, up front, says it once — and leaves nothing
        // half-created behind.
        for network in plan.networks {
            do {
                let created = try await adapter.ensureNetwork(network, projectName: plan.projectName)
                emit(.networkReady(network: network.resolvedName, created: created))
            } catch {
                emit(.networkFailed(network: network.resolvedName, reason: "\(error)"))
                for service in plan.services {
                    emit(.serviceSkipped(service: service.name, reason: .networkUnavailable))
                }
                emit(.done(success: false, ready: [], failed: [], skipped: plan.services.map(\.name)))
                return events
            }
        }

        // Volumes, for the same reason and with more at stake: a container
        // mounting a volume that does not exist gets an empty one invented for
        // it, so a missing external volume would otherwise look like success
        // right up until the data is gone.
        for volume in plan.volumes {
            do {
                let created = try await adapter.ensureVolume(volume, projectName: plan.projectName)
                // Only a volume this run created is a candidate: seeding an
                // existing one would overwrite data.
                if created { volumesAwaitingSeed.insert(volume.resolvedName) }
                emit(.volumeReady(volume: volume.resolvedName, created: created))
            } catch {
                emit(.volumeFailed(volume: volume.resolvedName, reason: "\(error)"))
                for service in plan.services {
                    emit(.serviceSkipped(service: service.name, reason: .volumeUnavailable))
                }
                emit(.done(success: false, ready: [], failed: [], skipped: plan.services.map(\.name)))
                return events
            }
        }

        let observed = (try? await adapter.observe(projectName: plan.projectName)) ?? []
        let waves = Reconciler.plan(desired: plan, observed: observed)
        let gatedOnHealth = Self.servicesGatedOnHealth(plan)

        var ready: [String] = []
        var failed: [String] = []
        var skipped: [String] = []
        var upstreamFailed = false

        for wave in waves {
            if upstreamFailed {
                // A wave never attempted because an earlier one failed. This is
                // the distinction `serviceSkipped` exists for: without it,
                // "never tried" and "tried and failed" look identical from the
                // outside, and a consumer cannot tell whether retrying THIS
                // service alone would help.
                for action in wave {
                    emit(.serviceSkipped(service: action.service.name, reason: .dependencyFailed))
                    skipped.append(action.service.name)
                }
                continue
            }

            // Actions within a wave have no ordering constraint on each other
            // by construction (that is what makes them a wave), so they run
            // concurrently, and each fires `onEvent` directly as its own steps
            // happen — a fast service's events are not held back by a slow one
            // in the same wave. The per-action event lists returned here are
            // used only to rebuild the final ordered array, since task
            // completion order is not deterministic and the array contract
            // must be.
            let results = await withTaskGroup(of: (String, [EngineEvent], Bool).self) { group in
                for action in wave {
                    group.addTask {
                        await self.executeCollectingEvents(
                            action,
                            projectName: plan.projectName,
                            gatedOnHealth: gatedOnHealth,
                            onEvent: onEvent
                        )
                    }
                }
                var collected: [(String, [EngineEvent], Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            // Sorted by service name for deterministic ordering in the
            // RETURNED array — onEvent above already fired in real completion
            // order, which is the live-progress signal; this is the stable
            // record for callers asserting on the array afterward.
            for (name, serviceEvents, succeeded) in results.sorted(by: { $0.0 < $1.0 }) {
                events.append(contentsOf: serviceEvents)
                if succeeded { ready.append(name) } else { failed.append(name); upstreamFailed = true }
            }
        }

        emit(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: skipped))
        return events
    }

    /// Stops every container observed for `projectName`. Unlike `up`, this
    /// does not reconcile against a plan — `down` always means "everything
    /// currently running for this project should stop", regardless of what
    /// the compose file says today.
    ///
    /// `remove` also deletes the networks this project created, matching what
    /// Compose does. `volumes` is deliberately a separate opt-in and not
    /// implied by `remove`: a network is cheap to rebuild, a volume IS the
    /// data, and no amount of convenience justifies deleting it because
    /// someone typed the flag that removes containers.
    @discardableResult
    public func down(
        projectName: String,
        remove: Bool,
        volumes: Bool = false,
        onEvent: (@Sendable (EngineEvent) -> Void)? = nil
    ) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        let observed = (try? await adapter.observe(projectName: projectName)) ?? []
        emit(.planned(services: observed.map(\.service), waves: [observed.map(\.service)]))

        var ready: [String] = []
        var failed: [String] = []

        let results = await withTaskGroup(of: (String, [EngineEvent], Bool).self) { group in
            for container in observed {
                group.addTask {
                    await self.executeTeardown(container, remove: remove, onEvent: onEvent)
                }
            }
            var collected: [(String, [EngineEvent], Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (name, serviceEvents, succeeded) in results.sorted(by: { $0.0 < $1.0 }) {
            events.append(contentsOf: serviceEvents)
            if succeeded { ready.append(name) } else { failed.append(name) }
        }

        // After the containers, never before: a network still holding one
        // cannot be deleted, and a volume still attached to one certainly
        // should not be. Skipped entirely if any teardown failed, since a
        // surviving container still needs them.
        if remove, failed.isEmpty {
            for name in (try? await adapter.removeNetworks(projectName: projectName)) ?? [] {
                emit(.resourceRemoved(kind: .network, name: name))
            }
        }
        if volumes, failed.isEmpty {
            for name in (try? await adapter.removeVolumes(projectName: projectName)) ?? [] {
                emit(.resourceRemoved(kind: .volume, name: name))
            }
        }

        emit(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: []))
        return events
    }

    /// Builds every service in `plan` that declares `build:`, concurrently.
    ///
    /// Unlike `up`'s waves, there is no dependency ordering here: Compose does
    /// not order builds by `depends_on` (a service depending on another at
    /// *runtime* says nothing about build order), so every buildable service
    /// builds in one wave. Services with only `image:` are silently skipped —
    /// matching `docker compose build`, not reported as failures, since
    /// "nothing to build" is the expected case for most services in a project.
    @discardableResult
    public func build(_ plan: Plan, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        let buildable = plan.services.filter { $0.build != nil }
        emit(.planned(services: buildable.map(\.name), waves: [buildable.map(\.name)]))

        var ready: [String] = []
        var failed: [String] = []

        let results = await withTaskGroup(of: (String, [EngineEvent], Bool).self) { group in
            for service in buildable {
                group.addTask {
                    await self.executeBuild(service, projectName: plan.projectName, onEvent: onEvent)
                }
            }
            var collected: [(String, [EngineEvent], Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (name, serviceEvents, succeeded) in results.sorted(by: { $0.0 < $1.0 }) {
            events.append(contentsOf: serviceEvents)
            if succeeded { ready.append(name) } else { failed.append(name) }
        }

        emit(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: []))
        return events
    }

    /// Pulls every service's `image:`, concurrently, without creating or
    /// starting anything. Services with only `build:` are skipped — matching
    /// `docker compose pull`, since there is nothing registry-side to pull.
    @discardableResult
    public func pull(_ plan: Plan, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runImageOperation(plan, state: .pulling, action: .pulled, onEvent: onEvent) { service in
            guard let image = service.image else { return nil }
            // `pull` is an explicit request to fetch, so the reported action
            // stays `.pulled` whether or not anything was transferred — unlike
            // `up`, where the distinction is the point.
            _ = try await self.adapter.ensureImage(image)
            return image
        }
    }

    /// Pushes every service's `image:` to its registry, concurrently. Only
    /// services with an explicit `image:` are eligible — an image built
    /// without one has no stable, caller-chosen reference to push under.
    @discardableResult
    public func push(_ plan: Plan, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runImageOperation(plan, state: .pushing, action: .pushed, onEvent: onEvent) { service in
            guard let image = service.image else { return nil }
            try await self.adapter.pushImage(image)
            return image
        }
    }

    /// Shared shape for `pull`/`push`: run `step` for every service `step`
    /// applies to (it returns nil to mean "not applicable, skip silently"),
    /// concurrently, with the same planned/state/ready-or-failed/done event
    /// pattern `build` uses. No dependency ordering, for the same reason
    /// `build` has none: neither operation touches a container.
    private func runImageOperation(
        _ plan: Plan,
        state: ServiceState,
        action: ImageAction,
        onEvent: (@Sendable (EngineEvent) -> Void)?,
        step: @escaping @Sendable (PlannedService) async throws -> String?
    ) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        let eligible = plan.services.filter { $0.image != nil }
        emit(.planned(services: eligible.map(\.name), waves: [eligible.map(\.name)]))

        var ready: [String] = []
        var failed: [String] = []

        let results = await withTaskGroup(of: (String, [EngineEvent], Bool).self) { group in
            for service in eligible {
                group.addTask {
                    var localEvents: [EngineEvent] = []
                    func localEmit(_ event: EngineEvent) {
                        localEvents.append(event)
                        onEvent?(event)
                    }
                    localEmit(.serviceState(service: service.name, state: state, detail: service.image))
                    do {
                        guard let result = try await step(service) else {
                            return (service.name, localEvents, true)
                        }
                        localEmit(.imageReady(service: service.name, image: result, action: action))
                        return (service.name, localEvents, true)
                    } catch {
                        localEmit(.serviceFailed(service: service.name, reason: "\(error)"))
                        return (service.name, localEvents, false)
                    }
                }
            }
            var collected: [(String, [EngineEvent], Bool)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (name, serviceEvents, succeeded) in results.sorted(by: { $0.0 < $1.0 }) {
            events.append(contentsOf: serviceEvents)
            if succeeded { ready.append(name) } else { failed.append(name) }
        }

        emit(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: []))
        return events
    }

    // MARK: - Execution

    private func executeCollectingEvents(
        _ action: ReconcileAction,
        projectName: String,
        gatedOnHealth: Set<String> = [],
        onEvent: (@Sendable (EngineEvent) -> Void)?
    ) async -> (String, [EngineEvent], Bool) {
        var events: [EngineEvent] = []
        let name = action.service.name
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        do {
            switch action {
            case .unchanged(let service, let containerID):
                emit(.serviceReady(service: service.name, containerID: containerID, reused: true))

            case .start(let service, let containerID):
                emit(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: containerID)
                try await waitHealthyIfNeeded(
                    service, containerID: containerID, gatedOnHealth: gatedOnHealth, emit: emit
                )
                emit(.serviceReady(service: name, containerID: containerID, reused: false))

            case .create(let service):
                let image = try await resolveImage(service, projectName: projectName, emit: emit)
                await seedNewVolumes(for: service, image: image, emit: emit)
                emit(.serviceState(service: name, state: .creating, detail: nil))
                let containerID = try await adapter.createContainer(for: service, image: image, projectName: projectName)
                emit(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: containerID)
                try await waitHealthyIfNeeded(
                    service, containerID: containerID, gatedOnHealth: gatedOnHealth, emit: emit
                )
                emit(.serviceReady(service: name, containerID: containerID, reused: false))

            case .recreate(let service, let containerID, let reason):
                emit(.serviceState(service: name, state: .recreating, detail: reason))
                try await adapter.stopContainer(id: containerID)
                try await adapter.deleteContainer(id: containerID, force: true)
                let image = try await resolveImage(service, projectName: projectName, emit: emit)
                await seedNewVolumes(for: service, image: image, emit: emit)
                emit(.serviceState(service: name, state: .creating, detail: nil))
                let newID = try await adapter.createContainer(for: service, image: image, projectName: projectName)
                emit(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: newID)
                try await waitHealthyIfNeeded(
                    service, containerID: newID, gatedOnHealth: gatedOnHealth, emit: emit
                )
                emit(.serviceReady(service: name, containerID: newID, reused: false))
            }
            return (name, events, true)
        } catch {
            emit(.serviceFailed(service: name, reason: "\(error)"))
            return (name, events, false)
        }
    }

    private func executeBuild(
        _ service: PlannedService,
        projectName: String,
        onEvent: (@Sendable (EngineEvent) -> Void)?
    ) async -> (String, [EngineEvent], Bool) {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        emit(.serviceState(service: service.name, state: .building, detail: service.build?.context))
        do {
            let image = try await adapter.buildImage(for: service, projectName: projectName)
            emit(.imageReady(service: service.name, image: image, action: .built))
            return (service.name, events, true)
        } catch {
            emit(.serviceFailed(service: service.name, reason: "\(error)"))
            return (service.name, events, false)
        }
    }

    private func executeTeardown(
        _ container: ObservedContainer,
        remove: Bool,
        onEvent: (@Sendable (EngineEvent) -> Void)?
    ) async -> (String, [EngineEvent], Bool) {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        emit(.serviceState(service: container.service, state: .stopping, detail: nil))
        do {
            try await adapter.stopContainer(id: container.containerID)
            if remove {
                emit(.serviceState(service: container.service, state: .removing, detail: nil))
                try await adapter.deleteContainer(id: container.containerID, force: true)
                emit(.serviceRemoved(service: container.service, containerID: container.containerID))
            } else {
                emit(.serviceStopped(service: container.service, containerID: container.containerID))
            }
            return (container.service, events, true)
        } catch {
            emit(.serviceFailed(service: container.service, reason: "\(error)"))
            return (container.service, events, false)
        }
    }

    /// Seeds any volume this run created that `service` is about to mount,
    /// from `service`'s own image at the path it mounts it on.
    ///
    /// Claimed from the pending set before the copy runs, so two services in
    /// the same wave mounting one volume cannot both seed it — the first to
    /// arrive wins, which is also Docker's rule.
    private func seedNewVolumes(
        for service: PlannedService,
        image: String,
        emit: (EngineEvent) -> Void
    ) async {
        for mount in service.volumes {
            guard let (volume, path) = Self.namedMount(mount),
                volumesAwaitingSeed.remove(volume) != nil
            else { continue }

            do {
                let seeded = try await adapter.seedVolume(volume, fromImage: image, atPath: path)
                if seeded {
                    emit(.volumeSeeded(volume: volume, fromImage: image, path: path))
                } else {
                    // Reported, not swallowed. A silent "could not seed" is
                    // indistinguishable from "did not need to", and the
                    // consequence surfaces much later as the container dying
                    // with EACCES for no stated reason.
                    emit(
                        .volumeSeedFailed(
                            volume: volume,
                            reason: "could not copy \(path) from \(image) — the image may have no shell"
                        )
                    )
                }
            } catch {
                // Not fatal: the container can still start, and it may well
                // not care. Saying so beats a later EACCES with no explanation.
                emit(.volumeSeedFailed(volume: volume, reason: "\(error)"))
            }
        }
    }

    /// Splits `source:target[:options]` into a named volume and its path,
    /// or nil when the source is a host path (a bind mount, which the host
    /// already owns) or there is no source at all.
    static func namedMount(_ mount: String) -> (volume: String, path: String)? {
        let parts = mount.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let source = parts[0]
        // A bind mount's source is a path; only a bare name is a volume.
        guard !source.isEmpty, !source.hasPrefix("/"), !source.hasPrefix(".") else { return nil }
        let target = parts[1]
        guard target.hasPrefix("/") else { return nil }
        return (source, target)
    }

    /// Blocks on a service's healthcheck only when another service is waiting
    /// on it with `condition: service_healthy`.
    ///
    /// A healthcheck describes how to ask whether a service is ready; it does
    /// not, on its own, make readiness a precondition of `up` succeeding.
    /// Compose gates on it exactly where a dependent says to. Treating every
    /// healthcheck as a gate means a service that is running perfectly well —
    /// but still migrating, or simply slower than its own declared retry
    /// budget — is reported as FAILED. That happened with n8n: the app was
    /// serving, and `up` said it had failed.
    private func waitHealthyIfNeeded(
        _ service: PlannedService,
        containerID: String,
        gatedOnHealth: Set<String>,
        emit: (EngineEvent) -> Void
    ) async throws {
        guard gatedOnHealth.contains(service.name) else { return }
        guard let healthcheck = service.healthcheck, !healthcheck.disabled else { return }
        emit(.serviceState(service: service.name, state: .waitingForHealthy, detail: nil))
        try await adapter.waitForHealthy(containerID: containerID, healthcheck: healthcheck)
    }

    /// Services some other service waits on with `service_healthy`.
    static func servicesGatedOnHealth(_ plan: Plan) -> Set<String> {
        var gated: Set<String> = []
        for service in plan.services {
            for dependency in service.dependsOn where dependency.condition == .healthy {
                gated.insert(dependency.service)
            }
        }
        return gated
    }

    /// Resolves the image a service should run: pulled when `image:` is set,
    /// built when only `build:` is. `Planner` already guarantees at least one
    /// is present (`PlanError.serviceMissingImageAndBuild`), so this is a
    /// genuine either/or, not a fallback chain — `image:` takes precedence
    /// when a service declares both, matching Compose's own documented
    /// behavior (build is used only to produce the image the first time; an
    /// explicit `image:` alongside `build:` names what to tag it as).
    private func resolveImage(_ service: PlannedService, projectName: String, emit: (EngineEvent) -> Void) async throws -> String {
        if let image = service.image {
            // Announced as `checkingImage` rather than `pulling`, because at
            // this point it is not known whether anything will be fetched.
            // Claiming "pulling" for what is usually a no-op is how a bug that
            // re-pulled every image on every run went unnoticed: the output
            // said it was pulling, so the time it took looked like the network.
            emit(.serviceState(service: service.name, state: .checkingImage, detail: image))
            let pulled = try await adapter.ensureImage(image)
            emit(.imageReady(service: service.name, image: image, action: pulled ? .pulled : .present))
            return image
        }
        emit(.serviceState(service: service.name, state: .building, detail: service.build?.context))
        return try await adapter.buildImage(for: service, projectName: projectName)
    }
}
