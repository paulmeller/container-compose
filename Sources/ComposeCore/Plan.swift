//
//  Plan.swift
//  container-compose
//

import Foundation

/// A fully-resolved service: everything needed to run it, with nothing left to
/// look up. Interpolation, `extends` and profile gating have all been applied,
/// so nothing downstream re-reads the compose document.
public struct PlannedService: Codable, Hashable, Sendable {
    /// Service name as written in the compose file.
    public let name: String

    /// Image reference to run, post-interpolation. `nil` only when the service
    /// is built from a Dockerfile and has not been built yet.
    public let image: String?

    /// Build context, if this service is built rather than pulled.
    public let build: PlannedBuild?

    public let command: [String]?
    public let entrypoint: [String]?
    public let environment: [String: String]
    public let ports: [String]
    public let volumes: [String]
    public let networks: [String]
    public let labels: [String: String]
    public let dependsOn: [ServiceDependency]
    public let healthcheck: PlannedHealthcheck?
    public let profiles: [String]

    /// Inner-loop configuration (`develop.watch`), acted on by the `watch`
    /// command. `nil` for a service with no `develop:` section, which is the
    /// common case — kept optional rather than an empty array so "no watch
    /// configured" and "watch configured with zero rules" stay distinguishable.
    public let develop: Develop?

    /// Options that map directly onto runtime flags. Kept as a bag rather than
    /// individual properties so adding a newly-supported key does not ripple
    /// through every layer above.
    public let runtimeOptions: [RuntimeOption]

    /// Compose keys this service declared that the target runtime cannot honor.
    /// Carried on the plan itself so a consumer can surface them *before*
    /// anything runs, rather than discovering them in log output afterwards.
    public let unsupported: [UnsupportedKey]

    /// Stable hash of everything above.
    ///
    /// This is what makes reconciliation decidable: stamp it on the container
    /// as a label, and a later plan can tell "identical, leave it alone" from
    /// "changed, must recreate" without guessing.
    public let configHash: String
}

/// A dependency edge, with the condition that must hold before this service
/// starts.
public struct ServiceDependency: Codable, Hashable, Sendable {
    public enum Condition: String, Codable, Sendable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completedSuccessfully = "service_completed_successfully"
    }

    public let service: String
    public let condition: Condition

    public init(service: String, condition: Condition = .started) {
        self.service = service
        self.condition = condition
    }
}

public struct PlannedBuild: Codable, Hashable, Sendable {
    public let context: String
    public let dockerfile: String?
    public let args: [String: String]
    public let target: String?
}

public struct PlannedHealthcheck: Codable, Hashable, Sendable {
    public let test: [String]
    public let interval: Double?
    public let timeout: Double?
    public let retries: Int?
    public let startPeriod: Double?
    public let disabled: Bool
}

/// One resolved runtime option, e.g. `--cap-add NET_ADMIN`.
public struct RuntimeOption: Codable, Hashable, Sendable {
    public let flag: String
    public let value: String?

    public init(flag: String, value: String? = nil) {
        self.flag = flag
        self.value = value
    }
}

/// A compose key the runtime cannot express, and why.
public struct UnsupportedKey: Codable, Hashable, Sendable {
    public enum Support: String, Codable, Sendable {
        /// Parsed, but nothing the runtime can do with it.
        case none
        /// Some of it applies; `detail` names what does.
        case partial
    }

    public let key: String
    public let support: Support
    public let reason: String
    public let detail: String?

    public init(key: String, support: Support, reason: String, detail: String? = nil) {
        self.key = key
        self.support = support
        self.reason = reason
        self.detail = detail
    }
}

/// A named volume the project declares.
public struct PlannedVolume: Codable, Hashable, Sendable {
    public let name: String
    /// Name as it exists in the runtime, after project namespacing.
    public let resolvedName: String
    public let external: Bool
}

/// A network the project declares.
public struct PlannedNetwork: Codable, Hashable, Sendable {
    public let name: String
    public let resolvedName: String
    public let external: Bool
}

/// The complete, immutable result of planning a compose project.
///
/// A value, deliberately: it can be hashed, compared, serialized, sent over the
/// protocol layer, and asserted against in tests without a runtime present.
public struct Plan: Codable, Hashable, Sendable {
    public let projectName: String

    /// Services in dependency order.
    public let services: [PlannedService]

    /// Services grouped into waves: everything in a wave has its dependencies
    /// satisfied by earlier waves and no dependency on a peer, so a wave can be
    /// started concurrently. Concatenating the waves yields a valid topological
    /// order.
    public let waves: [[String]]

    public let volumes: [PlannedVolume]
    public let networks: [PlannedNetwork]

    /// Look up a planned service by name.
    public func service(named name: String) -> PlannedService? {
        services.first { $0.name == name }
    }

    /// Every unsupported key across the project, as
    /// `(service, key)` pairs — what a consumer shows before running anything.
    public var unsupportedKeys: [(service: String, key: UnsupportedKey)] {
        services.flatMap { service in
            service.unsupported.map { (service: service.name, key: $0) }
        }
    }
}
