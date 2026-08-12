//
//  Reconciler.swift
//  container-compose
//

import Foundation

/// A service as it exists in the runtime right now, as reported by whatever is
/// observing it. Carries only what reconciliation needs to decide anything —
/// not a full container inspection.
public struct ObservedContainer: Sendable, Equatable, Codable {
    /// Compose project this container belongs to. Every container this tool
    /// creates always carries both labels together, so this is required, not
    /// optional — unlike `image`/`publishedPorts`, which depend on how much
    /// the adapter's list call reports.
    public let project: String
    public let service: String
    public let containerID: String
    public let running: Bool

    /// The `configHash` stamped as a label when this container was created, if
    /// any. `nil` for a container this tool did not create (or created before
    /// hashing existed) — treated as "unknown", which reconciliation resolves
    /// as if the configuration had changed, so an untracked container is
    /// brought under management rather than trusted blindly.
    public let configHash: String?

    /// The image reference this container was created from, when the adapter
    /// can report it. Not used by `Reconciler` (config-hash comparison already
    /// captures an image change) — carried so `ps`/`images`/`ls` are free from
    /// the same `observe()` call, rather than needing a second adapter round
    /// trip just to answer "what image is this running?"
    public let image: String?

    /// Ports this container publishes to the host, when the adapter can
    /// report them. Same reasoning as `image`: free for `ps`/`port` from data
    /// `observe()` already has to fetch.
    public let publishedPorts: [PublishedPort]

    public init(
        project: String,
        service: String,
        containerID: String,
        running: Bool,
        configHash: String?,
        image: String? = nil,
        publishedPorts: [PublishedPort] = []
    ) {
        self.project = project
        self.service = service
        self.containerID = containerID
        self.running = running
        self.configHash = configHash
        self.image = image
        self.publishedPorts = publishedPorts
    }
}

/// One published port binding, as reported by the runtime.
public struct PublishedPort: Sendable, Equatable, Codable {
    public let containerPort: Int
    public let hostPort: Int
    public let hostAddress: String

    public init(containerPort: Int, hostPort: Int, hostAddress: String) {
        self.containerPort = containerPort
        self.hostPort = hostPort
        self.hostAddress = hostAddress
    }
}

/// What reconciliation decided to do for one service.
public enum ReconcileAction: Sendable, Equatable {
    /// No container exists for this service yet.
    case create(service: PlannedService)

    /// A container exists, is stopped, and its configuration is unchanged —
    /// just needs starting.
    case start(service: PlannedService, containerID: String)

    /// A container exists but its configuration no longer matches the plan (or
    /// its provenance is unknown); it must be replaced. `reason` is surfaced to
    /// the consumer so "why is this recreating?" has a real answer.
    case recreate(service: PlannedService, containerID: String, reason: String)

    /// A container exists, is running, and matches the plan exactly. This is
    /// the case a delete-and-recreate implementation cannot express, and the
    /// one that makes clicking "start" on an already-running stack cheap
    /// instead of destructive.
    case unchanged(service: PlannedService, containerID: String)

    public var service: PlannedService {
        switch self {
        case .create(let service), .start(let service, _), .recreate(let service, _, _), .unchanged(let service, _):
            return service
        }
    }
}

/// Decides what must happen to make observed reality match a `Plan`.
///
/// This is the architectural center of the engine and, deliberately, still
/// pure: given a plan and what was observed, the actions to take are a
/// mathematical function of the two — no I/O, no clock, nothing ambient. That
/// is what makes "will this recreate my database container?" answerable in a
/// unit test instead of by trying it and hoping.
public enum Reconciler {

    /// - Returns: Actions grouped by wave, in start order. Waves preserve
    ///   `depends_on`; actions within one wave have no ordering constraint on
    ///   each other and are safe to execute concurrently.
    public static func plan(desired: Plan, observed: [ObservedContainer]) -> [[ReconcileAction]] {
        var byService: [String: ObservedContainer] = [:]
        for container in observed {
            byService[container.service] = container
        }

        return desired.waves.map { wave in
            wave.compactMap { name -> ReconcileAction? in
                guard let service = desired.service(named: name) else { return nil }
                return action(for: service, observed: byService[name])
            }
        }
    }

    private static func action(for service: PlannedService, observed: ObservedContainer?) -> ReconcileAction {
        guard let observed else {
            return .create(service: service)
        }

        guard observed.configHash == service.configHash else {
            let reason = observed.configHash == nil
                ? "existing container has no recorded configuration (not created by a config-hash-aware run)"
                : "service configuration changed since this container was created"
            return .recreate(service: service, containerID: observed.containerID, reason: reason)
        }

        return observed.running
            ? .unchanged(service: service, containerID: observed.containerID)
            : .start(service: service, containerID: observed.containerID)
    }
}
