//
//  CLIRenderer.swift
//  container-compose
//

import ComposeCore
import ComposeProtocol
import Foundation

/// Turns the `ProtocolMessage` stream into human-readable lines.
///
/// This is the entirety of what makes the CLI a CLI rather than the protocol
/// binary with different formatting — which is deliberate. `main.swift` calls
/// the identical `ProtocolRequest.parse` and `ProtocolRunner` the protocol
/// binary uses; the only code path that exists solely for this target is this
/// file. If the CLI ever needs a field `ProtocolMessage` does not carry, that
/// is immediately visible as a compile error here rather than something that
/// could silently grow into a capability the protocol layer lacks.
///
/// Stateful only in the narrow sense of remembering the column width for
/// alignment (seeded from the `.planned` message, which names every service up
/// front) — not a general rendering framework, on purpose.
///
/// `render` is called from `ProtocolRunner`'s `@Sendable`, non-async
/// callback, which fires from whichever concurrently-executing action inside
/// a wave produced the event — so this is genuinely accessed from more than
/// one thread at once, not just theoretically. A lock guards the one mutable
/// field; an `actor` was not an option here, since it would force `render`
/// to become `async` and the callback it is called from cannot be.
public final class CLIRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var serviceColumnWidth = 0

    public init() {}

    /// The line(s) to print for `message`, or nil when nothing should print
    /// for it. Never throws: a rendering layer that could fail would leave a
    /// consumer with no way to see what actually happened underneath it.
    public func render(_ message: ProtocolMessage) -> String? {
        switch message.type {
        case .capabilities:
            return renderCapabilities(message.capabilities)

        case .planned:
            let services = message.services ?? []
            lock.lock()
            serviceColumnWidth = max(services.map(\.count).max() ?? 0, minimumColumnWidth)
            lock.unlock()
            let waves = (message.waves ?? []).enumerated()
                .map { index, wave in "  wave \(index + 1): \(wave.joined(separator: ", "))" }
                .joined(separator: "\n")
            let plural = services.count == 1 ? "service" : "services"
            return "Plan: \(services.count) \(plural)\n\(waves)\n"

        case .serviceState:
            let detail = message.detail.map { " (\($0))" } ?? ""
            return column(message.service) + (message.state ?? "") + detail

        case .serviceReady:
            let mode = message.reused == true ? "reused" : "ready"
            let container = message.container.map { " -> \($0)" } ?? ""
            return column(message.service) + mode + container

        case .serviceStopped:
            return column(message.service) + "stopped" + (message.container.map { " -> \($0)" } ?? "")

        case .serviceRemoved:
            return column(message.service) + "removed" + (message.container.map { " -> \($0)" } ?? "")

        case .imageReady:
            let verb = message.action ?? "ready"
            return column(message.service) + verb + (message.image.map { " -> \($0)" } ?? "")

        case .serviceFailed:
            return column(message.service) + "FAILED: \(message.reason ?? "unknown error")"

        case .serviceSkipped:
            return column(message.service) + "skipped (\(message.reason ?? "unknown reason"))"

        case .networkReady:
            // Networks are project-level, not per-service, so "network" takes
            // the service column rather than the message sitting under one of
            // them — the same placement `docker compose` uses for "Network x
            // Created".
            let mode = message.reused == true ? "exists" : "created"
            return column("network") + "\(mode) -> \(message.network ?? "?")"

        case .networkFailed:
            return column("network")
                + "FAILED: \(message.network ?? "?") — \(message.reason ?? "unknown error")"

        case .done:
            let ready = message.ready ?? []
            let failed = message.failed ?? []
            let skipped = message.skipped ?? []
            let verb = message.success == true ? "succeeded" : "failed"
            var line = "\ndone: \(verb) — \(ready.count) ready, \(failed.count) failed"
            if !skipped.isEmpty { line += ", \(skipped.count) skipped" }
            return line

        case .error:
            return "error: \(message.message ?? "unknown error")"

        case .container:
            let project = message.project ?? ""
            let service = message.service ?? ""
            let state = message.state ?? ""
            let container = message.container ?? ""
            let image = message.image ?? ""
            let ports = (message.ports ?? []).joined(separator: ", ")
            return [project.isEmpty ? service : "\(project)/\(service)", state, container, image, ports]
                .filter { !$0.isEmpty }
                .joined(separator: "  ")

        case .config:
            return message.output ?? ""

        case .log:
            return column(message.service) + (message.line ?? "")

        case .output:
            guard let service = message.service else { return message.output ?? "" }
            return "\(service):\n\(message.output ?? "")"

        case .result:
            return message.output ?? ""
        }
    }

    private let minimumColumnWidth = 7

    private func column(_ service: String?) -> String {
        let name = service ?? ""
        lock.lock()
        let width = serviceColumnWidth
        lock.unlock()
        let padded = name.count >= width ? name : name + String(repeating: " ", count: width - name.count)
        return padded + "  "
    }

    private func renderCapabilities(_ capabilities: RuntimeCapabilities?) -> String {
        guard let capabilities else { return "capabilities: (none reported)" }
        let supported = (Set(capabilities.listFlags.keys)
            .union(capabilities.scalarFlags.keys)
            .union(capabilities.booleanFlags.keys))
            .sorted()
        var lines = ["Runtime capabilities:", "  supported: \(supported.joined(separator: ", "))"]
        if !capabilities.unsupported.isEmpty {
            lines.append("  unsupported:")
            for key in capabilities.unsupported.keys.sorted() {
                lines.append("    \(key) — \(capabilities.unsupported[key] ?? "")")
            }
        }
        if !capabilities.partial.isEmpty {
            lines.append("  partial:")
            for key in capabilities.partial.keys.sorted() {
                let info = capabilities.partial[key]
                lines.append("    \(key) — \(info?.reason ?? "") (supports: \(info?.supported.joined(separator: ", ") ?? ""))")
            }
        }
        return lines.joined(separator: "\n")
    }
}
