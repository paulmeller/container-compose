//
//  ProtocolRunner.swift
//  container-compose
//

import ComposeCore
import ComposeEngine
import Foundation

/// Executes a `ProtocolRequest` and produces the `ProtocolMessage` stream.
///
/// This is the entire substance of the protocol layer. `main.swift` in the
/// executable target is a thin wrapper around this — argv into a request,
/// this runner's messages onto stdout as NDJSON — so everything of actual
/// decision weight is unit-testable without spawning a process, exactly like
/// Core and Engine.
public struct ProtocolRunner: Sendable {
    private let adapter: RuntimeAdapter
    private let capabilities: RuntimeCapabilities
    private let files: ComposeFileProvider

    public init(
        adapter: RuntimeAdapter,
        capabilities: RuntimeCapabilities = .appleContainer,
        files: ComposeFileProvider = FileSystemProvider()
    ) {
        self.adapter = adapter
        self.capabilities = capabilities
        self.files = files
    }

    /// Runs `request`, calling `onMessage` for each line as it is produced —
    /// not batched at the end, so a consumer streaming this to a UI sees real
    /// progress. Returns the process exit code the caller should use.
    public func run(_ request: ProtocolRequest, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        switch request.command {
        case .capabilities:
            onMessage(.capabilitiesMessage(capabilities))
            return 0

        case .up(let services):
            return await runUp(request, services: services, onMessage: onMessage)

        case .down(let remove):
            return await runDown(request, remove: remove, onMessage: onMessage)
        }
    }

    private func runUp(_ request: ProtocolRequest, services: [String], onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let plan = resolvePlan(request, requestedServices: services, onMessage: onMessage) else { return 1 }

        let engine = Engine(adapter: adapter)
        let events = await engine.up(plan) { event in onMessage(ProtocolMessage(event)) }

        guard case .done(let success, _, _, _) = events.last else { return 1 }
        return success ? 0 : 1
    }

    private func runDown(_ request: ProtocolRequest, remove: Bool, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }

        let engine = Engine(adapter: adapter)
        let events = await engine.down(projectName: projectName, remove: remove) { event in
            onMessage(ProtocolMessage(event))
        }

        guard case .done(let success, _, _, _) = events.last else { return 1 }
        return success ? 0 : 1
    }

    // MARK: - Planning

    private func resolvePlan(_ request: ProtocolRequest, requestedServices: [String], onMessage: @escaping @Sendable (ProtocolMessage) -> Void) -> Plan? {
        guard let path = request.composeFilePath else {
            onMessage(.errorMessage("no compose file given"))
            return nil
        }
        guard let document = files.contents(atPath: path) else {
            onMessage(.errorMessage("compose file not found at '\(path)'"))
            return nil
        }
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return nil }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let variables = resolveVariables(request, directory: directory)

        do {
            return try Planner(files: files).plan(
                document: document,
                options: PlanOptions(
                    projectName: projectName,
                    directory: directory,
                    variables: variables,
                    activeProfiles: request.profiles,
                    requestedServices: requestedServices,
                    capabilities: capabilities
                )
            )
        } catch {
            onMessage(.errorMessage("\(error)"))
            return nil
        }
    }

    private func resolveProjectName(_ request: ProtocolRequest, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) -> String? {
        if let explicit = request.projectName { return explicit }
        guard let path = request.composeFilePath else {
            onMessage(.errorMessage("a project name or a compose file is required"))
            return nil
        }
        // The same convention Compose itself uses: the containing directory's
        // name, when nothing is declared explicitly.
        return URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
    }

    /// Process environment, with a project `.env` file's values filling in
    /// anything the shell did not already set — shell values take precedence,
    /// matching Compose's own documented precedence.
    private func resolveVariables(_ request: ProtocolRequest, directory: String) -> [String: String] {
        var variables = ProcessInfo.processInfo.environment
        let envPath = request.envFilePath ?? directory + "/.env"
        if let contents = files.contents(atPath: envPath) {
            variables.merge(Planner.parseEnvFile(contents)) { shellValue, _ in shellValue }
        }
        return variables
    }
}
