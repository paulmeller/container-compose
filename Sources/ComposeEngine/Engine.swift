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

        let observed = (try? await adapter.observe(projectName: plan.projectName)) ?? []
        let waves = Reconciler.plan(desired: plan, observed: observed)

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
                        await self.executeCollectingEvents(action, projectName: plan.projectName, onEvent: onEvent)
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
    @discardableResult
    public func down(projectName: String, remove: Bool, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
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

    // MARK: - Execution

    private func executeCollectingEvents(
        _ action: ReconcileAction,
        projectName: String,
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
                try await waitHealthyIfNeeded(service, containerID: containerID, emit: emit)
                emit(.serviceReady(service: name, containerID: containerID, reused: false))

            case .create(let service):
                let image = try await resolveImage(service, projectName: projectName, emit: emit)
                emit(.serviceState(service: name, state: .creating, detail: nil))
                let containerID = try await adapter.createContainer(for: service, image: image, projectName: projectName)
                emit(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: containerID)
                try await waitHealthyIfNeeded(service, containerID: containerID, emit: emit)
                emit(.serviceReady(service: name, containerID: containerID, reused: false))

            case .recreate(let service, let containerID, let reason):
                emit(.serviceState(service: name, state: .recreating, detail: reason))
                try await adapter.stopContainer(id: containerID)
                try await adapter.deleteContainer(id: containerID, force: true)
                let image = try await resolveImage(service, projectName: projectName, emit: emit)
                emit(.serviceState(service: name, state: .creating, detail: nil))
                let newID = try await adapter.createContainer(for: service, image: image, projectName: projectName)
                emit(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: newID)
                try await waitHealthyIfNeeded(service, containerID: newID, emit: emit)
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
            // Reuses `serviceReady`'s `containerID` field for the built image
            // reference rather than adding a build-only event case: the
            // meaning ("here is the identifier this step produced") is the
            // same, and a renderer already knows how to show it.
            emit(.serviceReady(service: service.name, containerID: image, reused: false))
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
            }
            emit(.serviceReady(service: container.service, containerID: container.containerID, reused: false))
            return (container.service, events, true)
        } catch {
            emit(.serviceFailed(service: container.service, reason: "\(error)"))
            return (container.service, events, false)
        }
    }

    private func waitHealthyIfNeeded(
        _ service: PlannedService,
        containerID: String,
        emit: (EngineEvent) -> Void
    ) async throws {
        guard let healthcheck = service.healthcheck, !healthcheck.disabled else { return }
        emit(.serviceState(service: service.name, state: .waitingForHealthy, detail: nil))
        try await adapter.waitForHealthy(containerID: containerID, healthcheck: healthcheck)
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
            emit(.serviceState(service: service.name, state: .pulling, detail: image))
            try await adapter.ensureImage(image)
            return image
        }
        emit(.serviceState(service: service.name, state: .building, detail: service.build?.context))
        return try await adapter.buildImage(for: service, projectName: projectName)
    }
}
