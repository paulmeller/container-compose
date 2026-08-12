//
//  EngineLifecycle.swift
//  container-compose
//
//  start/stop/restart/kill/rm/wait — control over already-created containers,
//  without the full down/up cycle those otherwise require. None of these need
//  Reconciler: there is no desired-vs-observed comparison, just "do this to
//  every targeted, already-existing container." They stay on Engine rather
//  than moving to ProtocolRunner because they share up/down's concurrent
//  execution + typed event stream shape, and duplicating that shape outside
//  Engine would be the same orchestration logic maintained twice.
//

import ComposeCore
import Foundation

extension Engine {

    /// Starts every targeted, non-running container for `projectName`.
    /// `services` empty means every service currently observed.
    @discardableResult
    public func start(projectName: String, services: [String] = [], onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runLifecycle(projectName: projectName, services: services, onEvent: onEvent) { container in
            if container.running { return nil }
            return { try await self.adapterStart(container) }
        }
    }

    /// Stops every targeted, running container. Unlike `down`, nothing is
    /// removed — the container survives, matching `docker compose stop`.
    @discardableResult
    public func stop(projectName: String, services: [String] = [], onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runLifecycle(projectName: projectName, services: services, onEvent: onEvent) { container in
            if !container.running { return nil }
            return { try await self.adapterStop(container) }
        }
    }

    /// Restarts every targeted container, composed as stop-then-start. The
    /// runtime has no restart verb — the same reason a Compose `restart:`
    /// policy cannot be honored at all (see `RuntimeCapabilities`).
    @discardableResult
    public func restart(projectName: String, services: [String] = [], onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runLifecycle(projectName: projectName, services: services, onEvent: onEvent) { container in
            { try await self.adapterRestart(container) }
        }
    }

    /// Sends `signal` to every targeted, running container.
    @discardableResult
    public func kill(projectName: String, services: [String] = [], signal: String, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runLifecycle(projectName: projectName, services: services, onEvent: onEvent) { container in
            if !container.running { return nil }
            return { try await self.adapterKill(container, signal: signal) }
        }
    }

    /// Removes every targeted, stopped container. A running one is skipped —
    /// reported via `serviceSkipped`, not silently ignored — unless `force`,
    /// which stops it first: matching `docker compose rm`, so an `rm` typo
    /// cannot take down a live stack by accident.
    @discardableResult
    public func rm(projectName: String, services: [String] = [], force: Bool, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        await runLifecycle(projectName: projectName, services: services, onEvent: onEvent) { container in
            if container.running && !force { return nil }
            return { try await self.adapterRemove(container) }
        }
    }

    /// Blocks until every targeted container stops running, or `timeoutSeconds`
    /// elapses. Polled rather than event-driven: the adapter exposes no
    /// wait-for-exit primitive, and a one-second tick is well inside the
    /// granularity anything waiting on a stack cares about.
    @discardableResult
    public func wait(projectName: String, services: [String] = [], timeoutSeconds: Double? = nil, onEvent: (@Sendable (EngineEvent) -> Void)? = nil) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }
        var lastObserved: [ObservedContainer] = []

        while true {
            let all = (try? await adapter.observe(projectName: projectName)) ?? []
            lastObserved = services.isEmpty ? all : all.filter { services.contains($0.service) }

            if lastObserved.isEmpty {
                emit(.planned(services: [], waves: [[]]))
                emit(.done(success: false, ready: [], failed: [], skipped: []))
                return events
            }

            if lastObserved.allSatisfy({ !$0.running }) { break }

            if let deadline, Date() >= deadline {
                emit(.planned(services: lastObserved.map(\.service), waves: [lastObserved.map(\.service)]))
                let stillRunning = lastObserved.filter(\.running).map(\.service)
                for name in stillRunning { emit(.serviceFailed(service: name, reason: "timed out waiting for exit")) }
                let stopped = lastObserved.filter { !$0.running }.map(\.service)
                for name in stopped { emit(.serviceReady(service: name, containerID: "", reused: true)) }
                emit(.done(success: false, ready: stopped, failed: stillRunning, skipped: []))
                return events
            }

            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        emit(.planned(services: lastObserved.map(\.service), waves: [lastObserved.map(\.service)]))
        for container in lastObserved {
            emit(.serviceReady(service: container.service, containerID: container.containerID, reused: true))
        }
        emit(.done(success: true, ready: lastObserved.map(\.service), failed: [], skipped: []))
        return events
    }

    // MARK: - Shared execution

    /// Observes `projectName`, filters to `services` (or everything, when
    /// empty), and runs `action(container)` for each — concurrently, since
    /// unlike `up` there is no dependency ordering between already-running
    /// containers being stopped or started. `action` returning nil means
    /// "nothing to do for this one" and reports it as skipped rather than
    /// silently omitting it, so the caller's counts always add up to the
    /// full targeted set.
    private func runLifecycle(
        projectName: String,
        services: [String],
        onEvent: (@Sendable (EngineEvent) -> Void)?,
        action: @escaping @Sendable (ObservedContainer) -> (@Sendable () async throws -> Void)?
    ) async -> [EngineEvent] {
        var events: [EngineEvent] = []
        func emit(_ event: EngineEvent) {
            events.append(event)
            onEvent?(event)
        }

        let all = (try? await adapter.observe(projectName: projectName)) ?? []
        let targeted = services.isEmpty ? all : all.filter { services.contains($0.service) }
        emit(.planned(services: targeted.map(\.service), waves: [targeted.map(\.service)]))

        var ready: [String] = []
        var failed: [String] = []
        var skipped: [String] = []

        let results = await withTaskGroup(of: (String, [EngineEvent], Outcome).self) { group in
            for container in targeted {
                group.addTask {
                    var localEvents: [EngineEvent] = []
                    func localEmit(_ event: EngineEvent) {
                        localEvents.append(event)
                        onEvent?(event)
                    }
                    guard let step = action(container) else {
                        localEmit(.serviceSkipped(service: container.service, reason: .dependencyFailed))
                        return (container.service, localEvents, .skipped)
                    }
                    do {
                        try await step()
                        localEmit(.serviceReady(service: container.service, containerID: container.containerID, reused: false))
                        return (container.service, localEvents, .succeeded)
                    } catch {
                        localEmit(.serviceFailed(service: container.service, reason: "\(error)"))
                        return (container.service, localEvents, .failed)
                    }
                }
            }
            var collected: [(String, [EngineEvent], Outcome)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (name, serviceEvents, outcome) in results.sorted(by: { $0.0 < $1.0 }) {
            events.append(contentsOf: serviceEvents)
            switch outcome {
            case .succeeded: ready.append(name)
            case .failed: failed.append(name)
            case .skipped: skipped.append(name)
            }
        }

        emit(.done(success: failed.isEmpty, ready: ready, failed: failed, skipped: skipped))
        return events
    }

    private enum Outcome { case succeeded, failed, skipped }

    private func adapterStart(_ container: ObservedContainer) async throws {
        try await adapter.startContainer(id: container.containerID)
    }

    private func adapterStop(_ container: ObservedContainer) async throws {
        try await adapter.stopContainer(id: container.containerID)
    }

    private func adapterRestart(_ container: ObservedContainer) async throws {
        if container.running { try await adapter.stopContainer(id: container.containerID) }
        try await adapter.startContainer(id: container.containerID)
    }

    private func adapterKill(_ container: ObservedContainer, signal: String) async throws {
        try await adapter.killContainer(id: container.containerID, signal: signal)
    }

    private func adapterRemove(_ container: ObservedContainer) async throws {
        if container.running { try await adapter.stopContainer(id: container.containerID) }
        try await adapter.deleteContainer(id: container.containerID, force: true)
    }
}
