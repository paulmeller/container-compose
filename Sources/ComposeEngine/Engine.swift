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
    private let adapter: RuntimeAdapter

    public init(adapter: RuntimeAdapter) {
        self.adapter = adapter
    }

    /// Reconciles `plan` against observed reality and returns the full event
    /// stream as an array.
    ///
    /// An array rather than `AsyncStream` at this layer: the ordering and
    /// content of events is what's being tested, and asserting on an array is
    /// direct. A streaming entry point for real consumers (CLI progress, a
    /// GUI updating live) is a thin wrapper added when something needs it —
    /// this is the contract that wrapper has to honor.
    @discardableResult
    public func up(_ plan: Plan) async -> [EngineEvent] {
        var events: [EngineEvent] = [.planned(services: plan.services.map(\.name), waves: plan.waves)]

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
                    events.append(.serviceSkipped(service: action.service.name, reason: .dependencyFailed))
                    skipped.append(action.service.name)
                }
                continue
            }

            // Actions within a wave have no ordering constraint on each other
            // by construction (that is what makes them a wave), so they run
            // concurrently. Collecting into an array preserves this method's
            // event-array contract while still executing in parallel.
            let results = await withTaskGroup(of: (String, [EngineEvent], Bool).self) { group in
                for action in wave {
                    group.addTask {
                        await self.executeCollectingEvents(action, projectName: plan.projectName)
                    }
                }
                var collected: [(String, [EngineEvent], Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            // Sorted by service name for deterministic event ordering — the
            // task group above completes in whatever order the I/O finishes,
            // and non-deterministic event order would make this untestable.
            for (name, serviceEvents, succeeded) in results.sorted(by: { $0.0 < $1.0 }) {
                events.append(contentsOf: serviceEvents)
                if succeeded { ready.append(name) } else { failed.append(name); upstreamFailed = true }
            }
        }

        events.append(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: skipped))
        return events
    }

    /// Stops every container observed for `projectName`. Unlike `up`, this
    /// does not reconcile against a plan — `down` always means "everything
    /// currently running for this project should stop", regardless of what
    /// the compose file says today.
    @discardableResult
    public func down(projectName: String, remove: Bool) async -> [EngineEvent] {
        let observed = (try? await adapter.observe(projectName: projectName)) ?? []
        var events: [EngineEvent] = [.planned(services: observed.map(\.service), waves: [observed.map(\.service)])]

        var ready: [String] = []
        var failed: [String] = []

        let results = await withTaskGroup(of: (String, [EngineEvent], Bool).self) { group in
            for container in observed {
                group.addTask {
                    await self.executeTeardown(container, remove: remove)
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

        events.append(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: []))
        return events
    }

    // MARK: - Execution

    private func executeCollectingEvents(_ action: ReconcileAction, projectName: String) async -> (String, [EngineEvent], Bool) {
        var events: [EngineEvent] = []
        let name = action.service.name

        do {
            switch action {
            case .unchanged(let service, let containerID):
                events.append(.serviceReady(service: service.name, containerID: containerID, reused: true))

            case .start(let service, let containerID):
                events.append(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: containerID)
                try await waitHealthyIfNeeded(service, containerID: containerID, events: &events)
                events.append(.serviceReady(service: name, containerID: containerID, reused: false))

            case .create(let service):
                if let image = service.image {
                    events.append(.serviceState(service: name, state: .pulling, detail: image))
                    try await adapter.ensureImage(image)
                }
                events.append(.serviceState(service: name, state: .creating, detail: nil))
                let containerID = try await adapter.createContainer(for: service, projectName: projectName)
                events.append(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: containerID)
                try await waitHealthyIfNeeded(service, containerID: containerID, events: &events)
                events.append(.serviceReady(service: name, containerID: containerID, reused: false))

            case .recreate(let service, let containerID, let reason):
                events.append(.serviceState(service: name, state: .recreating, detail: reason))
                try await adapter.stopContainer(id: containerID)
                try await adapter.deleteContainer(id: containerID, force: true)
                if let image = service.image {
                    events.append(.serviceState(service: name, state: .pulling, detail: image))
                    try await adapter.ensureImage(image)
                }
                events.append(.serviceState(service: name, state: .creating, detail: nil))
                let newID = try await adapter.createContainer(for: service, projectName: projectName)
                events.append(.serviceState(service: name, state: .starting, detail: nil))
                try await adapter.startContainer(id: newID)
                try await waitHealthyIfNeeded(service, containerID: newID, events: &events)
                events.append(.serviceReady(service: name, containerID: newID, reused: false))
            }
            return (name, events, true)
        } catch {
            events.append(.serviceFailed(service: name, reason: "\(error)"))
            return (name, events, false)
        }
    }

    private func executeTeardown(_ container: ObservedContainer, remove: Bool) async -> (String, [EngineEvent], Bool) {
        var events: [EngineEvent] = [.serviceState(service: container.service, state: .stopping, detail: nil)]
        do {
            try await adapter.stopContainer(id: container.containerID)
            if remove {
                events.append(.serviceState(service: container.service, state: .removing, detail: nil))
                try await adapter.deleteContainer(id: container.containerID, force: true)
            }
            events.append(.serviceReady(service: container.service, containerID: container.containerID, reused: false))
            return (container.service, events, true)
        } catch {
            events.append(.serviceFailed(service: container.service, reason: "\(error)"))
            return (container.service, events, false)
        }
    }

    private func waitHealthyIfNeeded(_ service: PlannedService, containerID: String, events: inout [EngineEvent]) async throws {
        guard let healthcheck = service.healthcheck, !healthcheck.disabled else { return }
        events.append(.serviceState(service: service.name, state: .waitingForHealthy, detail: nil))
        try await adapter.waitForHealthy(containerID: containerID, healthcheck: healthcheck)
    }
}
