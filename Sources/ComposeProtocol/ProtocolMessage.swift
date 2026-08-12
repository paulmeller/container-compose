//
//  ProtocolMessage.swift
//  container-compose
//

import ComposeCore
import ComposeEngine
import Foundation

/// One line of the NDJSON stream a consumer reads from stdout.
///
/// Deliberately a flat, tagged struct rather than a mirror of `EngineEvent`'s
/// Swift enum shape. A cross-language wire contract needs a discriminator
/// field and optional siblings — the representation any language's JSON
/// decoder handles without special-casing enum-as-single-key-object encoding.
/// This also decouples the wire format from `EngineEvent`'s internal shape:
/// the Swift type can be refactored freely as long as the mapping in this
/// file keeps producing the same JSON.
///
/// `version` is the wire format's own version, independent of the package
/// version — bump it only when a field's MEANING changes incompatibly, not
/// when a field is added (an added optional field is safe for any consumer
/// that already ignores unknown fields, which is the norm for JSON).
public struct ProtocolMessage: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let type: MessageType

    // Present on capabilities messages.
    public let capabilities: RuntimeCapabilities?

    // Present on planned.
    public let services: [String]?
    public let waves: [[String]]?

    // Present on service_state, service_ready, service_failed, service_skipped.
    public let service: String?
    public let state: String?
    public let detail: String?
    public let container: String?
    public let reused: Bool?
    public let reason: String?

    // Present on done.
    public let success: Bool?
    public let ready: [String]?
    public let failed: [String]?
    public let skipped: [String]?

    // Present on error (a request-level failure — bad compose file, unknown
    // service — that never reached the engine at all).
    public let message: String?

    // Present on `container` (ps/ls/images/port): one observed container's
    // info per message, rather than a single batched array, so a consumer
    // can render rows as they arrive exactly like every other command here.
    public let project: String?
    public let image: String?
    // Pre-formatted "hostAddress:hostPort->containerPort/proto" strings
    // rather than a nested struct: every consumer wants to display these,
    // none has shown a need to recompute them, and a flat string list keeps
    // the wire format simple for the cross-language case this protocol
    // exists for.
    public let ports: [String]?

    // Present on `log` (logs): one line per message, as it arrives.
    public let line: String?

    // Present on `output` (config/top/stats) and `result` (cp/export): a
    // single opaque text blob — rendered as-is, since the source has no
    // structured form (top/stats are runtime-formatted passthrough text) or
    // the whole point is the operation's own result message (cp/export).
    public let output: String?

    // Present on `image_ready` (build/pull/push): which of the three
    // happened, so this message reads correctly without the reader having
    // tracked which top-level command produced it. `image` (above) carries
    // the resulting reference.
    public let action: String?

    public init(
        type: MessageType,
        capabilities: RuntimeCapabilities? = nil,
        services: [String]? = nil,
        waves: [[String]]? = nil,
        service: String? = nil,
        state: String? = nil,
        detail: String? = nil,
        container: String? = nil,
        reused: Bool? = nil,
        reason: String? = nil,
        success: Bool? = nil,
        ready: [String]? = nil,
        failed: [String]? = nil,
        skipped: [String]? = nil,
        message: String? = nil,
        project: String? = nil,
        image: String? = nil,
        ports: [String]? = nil,
        line: String? = nil,
        output: String? = nil,
        action: String? = nil
    ) {
        self.version = Self.currentVersion
        self.type = type
        self.capabilities = capabilities
        self.services = services
        self.waves = waves
        self.service = service
        self.state = state
        self.detail = detail
        self.container = container
        self.reused = reused
        self.reason = reason
        self.success = success
        self.ready = ready
        self.failed = failed
        self.skipped = skipped
        self.message = message
        self.project = project
        self.image = image
        self.ports = ports
        self.line = line
        self.output = output
        self.action = action
    }

    public enum MessageType: String, Codable, Sendable {
        case capabilities
        case planned
        case serviceState = "service_state"
        case serviceReady = "service_ready"
        /// A container was stopped but still exists — `down` (no `--remove`),
        /// `stop`, `kill`.
        case serviceStopped = "service_stopped"
        /// A container no longer exists — `down --remove`, `rm`.
        case serviceRemoved = "service_removed"
        /// An image was built, pulled, or pushed — see `action`.
        case imageReady = "image_ready"
        case serviceFailed = "service_failed"
        case serviceSkipped = "service_skipped"
        case done
        case error
        /// One observed container — ps/ls/images/port.
        case container
        /// The fully-resolved plan, rendered as text — config.
        case config
        /// One log line — logs.
        case log
        /// An opaque runtime-formatted text blob — top/stats.
        case output
        /// A one-shot operation's outcome — cp/export.
        case result
    }
}

extension ProtocolMessage {
    /// Translates an internal `EngineEvent` into the wire format. The one
    /// place this mapping exists — nothing else in the protocol or CLI layers
    /// should construct a `ProtocolMessage` by hand for an engine event.
    public init(_ event: EngineEvent) {
        switch event {
        case .planned(let services, let waves):
            self.init(type: .planned, services: services, waves: waves)

        case .serviceState(let service, let state, let detail):
            self.init(type: .serviceState, service: service, state: state.rawValue, detail: detail)

        case .serviceReady(let service, let container, let reused):
            self.init(type: .serviceReady, service: service, container: container, reused: reused)

        case .serviceStopped(let service, let container):
            self.init(type: .serviceStopped, service: service, container: container)

        case .serviceRemoved(let service, let container):
            self.init(type: .serviceRemoved, service: service, container: container)

        case .imageReady(let service, let image, let action):
            self.init(type: .imageReady, service: service, image: image, action: action.rawValue)

        case .serviceFailed(let service, let reason):
            self.init(type: .serviceFailed, service: service, reason: reason)

        case .serviceSkipped(let service, let reason):
            self.init(type: .serviceSkipped, service: service, reason: reason.rawValue)

        case .done(let success, let ready, let failed, let skipped):
            self.init(type: .done, success: success, ready: ready, failed: failed, skipped: skipped)
        }
    }

    /// A capability-manifest message — the answer to "what will actually work
    /// here?", independent of any particular compose file.
    public static func capabilitiesMessage(_ capabilities: RuntimeCapabilities) -> ProtocolMessage {
        ProtocolMessage(type: .capabilities, capabilities: capabilities)
    }

    /// A request-level failure: the compose file didn't parse, a named
    /// service doesn't exist, etc. Distinct from `serviceFailed`, which means
    /// the engine attempted something and it failed — an `error` message
    /// means the engine was never reached at all.
    public static func errorMessage(_ text: String) -> ProtocolMessage {
        ProtocolMessage(type: .error, message: text)
    }

    /// One row of `ps`/`ls`/`images`/`port` output — an observed container,
    /// translated to the wire format's flat shape. `project` is always
    /// present here (unlike on other message types) since `ls` spans
    /// multiple projects and needs it to disambiguate same-named services.
    public static func containerMessage(_ container: ObservedContainer) -> ProtocolMessage {
        ProtocolMessage(
            type: .container,
            service: container.service,
            state: container.running ? "running" : "stopped",
            container: container.containerID,
            project: container.project,
            image: container.image,
            ports: container.publishedPorts.isEmpty ? nil : container.publishedPorts.map { $0.wireFormat }
        )
    }

    public static func configMessage(_ rendered: String) -> ProtocolMessage {
        ProtocolMessage(type: .config, output: rendered)
    }

    public static func logMessage(service: String, line: String) -> ProtocolMessage {
        ProtocolMessage(type: .log, service: service, line: line)
    }

    public static func outputMessage(service: String? = nil, text: String) -> ProtocolMessage {
        ProtocolMessage(type: .output, service: service, output: text)
    }

    public static func resultMessage(_ text: String) -> ProtocolMessage {
        ProtocolMessage(type: .result, output: text)
    }
}

extension PublishedPort {
    var wireFormat: String {
        "\(hostAddress):\(hostPort)->\(containerPort)"
    }
}
