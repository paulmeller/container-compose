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
///
/// Commands split two ways, matching the design's command-routing decision:
/// Engine-owned commands (`up`/`down`/`build`/`pull`/`push`/`start`/`stop`/
/// `restart`/`kill`/`rm`/`wait`) need Reconciler and/or concurrent
/// multi-service orchestration with the typed event stream, so they go
/// through `Engine`. Everything else (`ps`/`ls`/`images`/`port`/`config`/
/// `logs`/`exec`/`cp`/`top`/`stats`/`watch`) acts on already-existing single
/// containers or is pure observation, and calls the adapter directly —
/// routing it through Engine's reconcile-and-wave machinery would buy
/// nothing and cost a layer of indirection.
///
/// `exec`/`run` are the one deliberate exception to the message-stream
/// contract: `run(_:onMessage:)` never produces a `.exec`/`.run` case (see
/// `runPassthrough`, a separate entry point `main.swift` calls instead).
public struct ProtocolRunner: Sendable {
    private let adapter: RuntimeAdapter
    private let capabilities: RuntimeCapabilities
    private let files: ComposeFileProvider

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

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
    ///
    /// Never called for `.exec`/`.run` — those go through `runPassthrough`
    /// instead, since they bypass this message stream entirely.
    public func run(_ request: ProtocolRequest, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        switch request.command {
        case .capabilities:
            onMessage(.capabilitiesMessage(capabilities))
            return 0

        case .up(let services):
            return await runUp(request, services: services, onMessage: onMessage)

        case .down(let remove, let volumes):
            return await runDown(request, remove: remove, volumes: volumes, onMessage: onMessage)

        case .build(let services):
            return await runPlanOperation(request, services: services, onMessage: onMessage) { engine, plan, onEvent in
                await engine.build(plan, onEvent: onEvent)
            }

        case .pull(let services):
            return await runPlanOperation(request, services: services, onMessage: onMessage) { engine, plan, onEvent in
                await engine.pull(plan, onEvent: onEvent)
            }

        case .push(let services):
            return await runPlanOperation(request, services: services, onMessage: onMessage) { engine, plan, onEvent in
                await engine.push(plan, onEvent: onEvent)
            }

        case .start(let services):
            return await runLifecycle(request, onMessage: onMessage) { engine, projectName, onEvent in
                await engine.start(projectName: projectName, services: services, onEvent: onEvent)
            }

        case .stop(let services):
            return await runLifecycle(request, onMessage: onMessage) { engine, projectName, onEvent in
                await engine.stop(projectName: projectName, services: services, onEvent: onEvent)
            }

        case .restart(let services):
            return await runLifecycle(request, onMessage: onMessage) { engine, projectName, onEvent in
                await engine.restart(projectName: projectName, services: services, onEvent: onEvent)
            }

        case .kill(let services, let signal):
            return await runLifecycle(request, onMessage: onMessage) { engine, projectName, onEvent in
                await engine.kill(projectName: projectName, services: services, signal: signal, onEvent: onEvent)
            }

        case .rm(let services, let force):
            return await runLifecycle(request, onMessage: onMessage) { engine, projectName, onEvent in
                await engine.rm(projectName: projectName, services: services, force: force, onEvent: onEvent)
            }

        case .wait(let services, let timeoutSeconds):
            return await runLifecycle(request, onMessage: onMessage) { engine, projectName, onEvent in
                await engine.wait(projectName: projectName, services: services, timeoutSeconds: timeoutSeconds, onEvent: onEvent)
            }

        case .ps(let all):
            return await runPs(request, all: all, onMessage: onMessage)

        case .ls(let all):
            return await runLs(all: all, onMessage: onMessage)

        case .images:
            return await runImages(request, onMessage: onMessage)

        case .config:
            return runConfig(request, onMessage: onMessage)

        case .translate(let force):
            return runTranslate(request, force: force, onMessage: onMessage)

        case .logs(let services, let follow, let tail):
            return await runLogs(request, services: services, follow: follow, tail: tail, onMessage: onMessage)

        case .top(let services):
            return await runTop(request, services: services, onMessage: onMessage)

        case .stats(let services):
            return await runStats(request, services: services, onMessage: onMessage)

        case .port(let service, let containerPort):
            return await runPort(request, service: service, containerPort: containerPort, onMessage: onMessage)

        case .cp(let source, let destination):
            return await runCp(request, source: source, destination: destination, onMessage: onMessage)

        case .export(let service, let outputPath):
            return await runExport(request, service: service, outputPath: outputPath, onMessage: onMessage)

        case .watch(let services):
            return await runWatch(request, services: services, onMessage: onMessage)

        case .exec, .run:
            // Programmer error: main.swift must route these to
            // `runPassthrough` before ever reaching this switch.
            onMessage(.errorMessage("exec/run do not use the message stream"))
            return 1
        }
    }

    /// The passthrough entry point for `.exec`/`.run` — inherited-stdio
    /// process execution with no NDJSON emitted at all, per
    /// `RuntimeAdapter.execPassthrough`'s documented exception. `main.swift`
    /// calls this instead of `run(_:onMessage:)` when it sees either command,
    /// and writes any resolution error to stderr itself (there is no message
    /// stream for it to go on).
    public func runPassthrough(_ request: ProtocolRequest) async -> (exitCode: Int32, error: String?) {
        switch request.command {
        case .exec(let service, let command, let tty):
            guard let projectName = resolveProjectNamePlain(request) else {
                return (1, "a project name or a compose file is required")
            }
            guard let observed = try? await adapter.observe(projectName: projectName),
                  let container = observed.first(where: { $0.service == service }) else {
                return (1, "no container for service '\(service)' in project '\(projectName)'")
            }
            let exitCode = (try? await adapter.execPassthrough(containerID: container.containerID, command: command, tty: tty)) ?? 127
            return (exitCode, nil)

        case .run(let service, let command, let remove, let tty):
            guard let plan = resolvePlanPlain(request, requestedServices: [service]) else {
                return (1, "failed to resolve a plan for service '\(service)'")
            }
            guard let planned = plan.service(named: service) else {
                return (1, "no such service '\(service)'")
            }
            do {
                let image: String
                if let explicit = planned.image {
                    try await adapter.ensureImage(explicit)
                    image = explicit
                } else {
                    image = try await adapter.buildImage(for: planned, projectName: plan.projectName)
                }
                let exitCode = try await adapter.runPassthrough(
                    image: image,
                    command: command,
                    environment: planned.environment,
                    workingDirectory: nil,
                    labels: [
                        "com.docker.compose.project": plan.projectName,
                        "com.docker.compose.service": planned.name,
                    ],
                    remove: remove,
                    tty: tty
                )
                return (exitCode, nil)
            } catch {
                return (1, "\(error)")
            }

        default:
            return (1, "runPassthrough called for a non-passthrough command")
        }
    }

    // MARK: - Engine-owned: up/down

    private func runUp(_ request: ProtocolRequest, services: [String], onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let plan = resolvePlan(request, requestedServices: services, onMessage: onMessage) else { return 1 }

        let engine = Engine(adapter: adapter)
        let events = await engine.up(plan) { event in onMessage(ProtocolMessage(event)) }

        guard case .done(let success, _, _, _) = events.last else { return 1 }
        return success ? 0 : 1
    }

    private func runDown(
        _ request: ProtocolRequest,
        remove: Bool,
        volumes: Bool,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }

        let engine = Engine(adapter: adapter)
        let events = await engine.down(projectName: projectName, remove: remove, volumes: volumes) { event in
            onMessage(ProtocolMessage(event))
        }

        guard case .done(let success, _, _, _) = events.last else { return 1 }
        return success ? 0 : 1
    }

    // MARK: - Engine-owned: build/pull/push

    /// Shared shape for the three whole-plan, no-container-lifecycle
    /// operations: resolve a plan, hand it to one `Engine` method, translate
    /// its terminal `.done` event into an exit code.
    private func runPlanOperation(
        _ request: ProtocolRequest,
        services: [String],
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void,
        operation: @escaping @Sendable (Engine, Plan, @escaping @Sendable (EngineEvent) -> Void) async -> [EngineEvent]
    ) async -> Int32 {
        guard let plan = resolvePlan(request, requestedServices: services, onMessage: onMessage) else { return 1 }
        let engine = Engine(adapter: adapter)
        let events = await operation(engine, plan) { event in onMessage(ProtocolMessage(event)) }
        guard case .done(let success, _, _, _) = events.last else { return 1 }
        return success ? 0 : 1
    }

    // MARK: - Engine-owned: start/stop/restart/kill/rm/wait

    /// Shared shape for the six already-created-container operations: none
    /// need a compose file, only a resolved project name (matching `down`).
    private func runLifecycle(
        _ request: ProtocolRequest,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void,
        operation: @escaping @Sendable (Engine, String, @escaping @Sendable (EngineEvent) -> Void) async -> [EngineEvent]
    ) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        let engine = Engine(adapter: adapter)
        let events = await operation(engine, projectName) { event in onMessage(ProtocolMessage(event)) }
        guard case .done(let success, _, _, _) = events.last else { return 1 }
        return success ? 0 : 1
    }

    // MARK: - Direct-to-adapter: observation

    private func runPs(_ request: ProtocolRequest, all: Bool, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName) else {
            onMessage(.errorMessage("failed to observe containers for project '\(projectName)'"))
            return 1
        }
        let rows = all ? observed : observed.filter { $0.running }
        for row in rows.sorted(by: { $0.service < $1.service }) {
            onMessage(.containerMessage(row))
        }
        return 0
    }

    private func runLs(all: Bool, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let observed = try? await adapter.observeAllProjects() else {
            onMessage(.errorMessage("failed to observe containers"))
            return 1
        }
        let rows = all ? observed : observed.filter { $0.running }
        for row in rows.sorted(by: { ($0.project, $0.service) < ($1.project, $1.service) }) {
            onMessage(.containerMessage(row))
        }
        return 0
    }

    private func runImages(_ request: ProtocolRequest, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName) else {
            onMessage(.errorMessage("failed to observe containers for project '\(projectName)'"))
            return 1
        }
        for row in observed.sorted(by: { $0.service < $1.service }) {
            onMessage(.containerMessage(row))
        }
        return 0
    }

    private func runConfig(_ request: ProtocolRequest, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) -> Int32 {
        guard let plan = resolvePlan(request, requestedServices: [], onMessage: onMessage) else { return 1 }
        guard let data = try? Self.jsonEncoder.encode(plan), let text = String(data: data, encoding: .utf8) else {
            onMessage(.errorMessage("failed to render the resolved plan"))
            return 1
        }
        onMessage(.configMessage(text))
        return 0
    }

    /// Resolves a Coolify template's generated variables into a plain env file.
    ///
    /// The compose document is deliberately NOT rewritten. Round-tripping it
    /// through the YAML parser would discard every comment — and in these
    /// templates the comments carry the catalogue metadata (`# category:`,
    /// `# documentation:`), which is most of what makes one readable. Since a
    /// bare `- SERVICE_X` entry now inherits from the environment, writing the
    /// values into `.env` beside the file is enough to make the original
    /// template run unmodified.
    ///
    /// Existing values are never overwritten without `--force`, and that is
    /// the whole point rather than a nicety: regenerating a password changes
    /// the service's configHash — so every container is recreated — and any
    /// database already initialised with the old password rejects the new one.
    private func runTranslate(
        _ request: ProtocolRequest,
        force: Bool,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) -> Int32 {
        guard let composePath = request.composeFilePath else {
            onMessage(.errorMessage("translate needs a compose file: pass --file"))
            return 1
        }
        guard let document = files.contents(atPath: composePath) else {
            onMessage(.errorMessage("could not read '\(composePath)'"))
            return 1
        }

        let directory = (composePath as NSString).deletingLastPathComponent
        let envPath = request.envFilePath ?? (directory.isEmpty ? ".env" : directory + "/.env")

        let existing = files.contents(atPath: envPath).map(Planner.parseEnvFile) ?? [:]
        let variables: [MagicVariable]
        do {
            variables = try MagicVariable.scan(document: document)
        } catch {
            onMessage(.errorMessage("could not scan '\(composePath)': \(error)"))
            return 1
        }

        guard !variables.isEmpty else {
            onMessage(.resultMessage("no generated SERVICE_* variables found in \(composePath)"))
            return 0
        }

        var generator = SystemRandomNumberGenerator()
        var resolved = existing
        var generated: [String] = []
        var kept: [String] = []

        // Grouped by base name, because the bare spelling is not independent
        // of the ported ones. A template declares `SERVICE_URL_N8N_5678` and
        // then references `${SERVICE_URL_N8N}` meaning the same address —
        // generating a value for the bare form on its own produces
        // `http://localhost`, silently dropping the port, and n8n would build
        // every webhook URL against the wrong one.
        for (base, group) in Dictionary(grouping: variables, by: \.baseName).sorted(by: { $0.key < $1.key }) {
            let ported = group.filter { $0.port != nil }.sorted { ($0.port ?? 0) < ($1.port ?? 0) }

            func value(for variable: MagicVariable) {
                let name = variable.declaredName
                if !force, let current = existing[name], !current.isEmpty {
                    kept.append(name)
                } else {
                    resolved[name] = variable.generatedValue(using: &generator)
                    generated.append(name)
                }
            }

            // Each declared port keeps its own address.
            for variable in ported { value(for: variable) }

            // The bare spelling follows the lowest port rather than generating
            // separately — arbitrary where a name is exposed on several, but
            // deterministic, and far better than an address pointing nowhere.
            // With no ported sibling (every credential, and URLs declared
            // without a port) it is generated normally.
            if let canonical = ported.first {
                if force || existing[base]?.isEmpty != false {
                    resolved[base] = resolved[canonical.declaredName]
                }
            } else if let bare = group.first(where: { $0.declaredName == base }) {
                value(for: bare)
            }
        }

        guard Self.write(envFile: resolved, to: envPath) else {
            onMessage(.errorMessage("could not write '\(envPath)'"))
            return 1
        }

        for name in generated.sorted() {
            onMessage(.resultMessage("generated \(name)"))
        }
        for name in kept.sorted() {
            onMessage(.resultMessage("kept \(name) (already set — pass --force to regenerate)"))
        }

        let ignoreNote = Self.ensureGitIgnored(envPath: envPath, directory: directory)
        onMessage(.resultMessage("wrote \(resolved.count) variables to \(envPath)"))
        if let ignoreNote { onMessage(.resultMessage(ignoreNote)) }
        onMessage(
            .resultMessage(
                "\(envPath) holds real credentials — it must not be committed"
            )
        )
        return 0
    }

    /// Writes `KEY=value` lines, sorted so the file has a stable diff between
    /// runs rather than reordering itself every time.
    private static func write(envFile values: [String: String], to path: String) -> Bool {
        let body = values.keys.sorted()
            .map { "\($0)=\(values[$0] ?? "")" }
            .joined(separator: "\n")
        let contents = """
            # Generated by `container-compose translate`.
            # Values are stable across runs on purpose: regenerating them would
            # change each service's config hash (recreating every container) and
            # would be rejected by any database already initialised with the old
            # credentials. Edit a value only if you mean to rotate it.
            \(body)

            """
        return (try? contents.write(toFile: path, atomically: true, encoding: .utf8)) != nil
    }

    /// Adds the env file to `.gitignore` when the directory is inside a git
    /// repository. Returns a note when something changed, so the caller can
    /// say so rather than editing a tracked file silently.
    private static func ensureGitIgnored(envPath: String, directory: String) -> String? {
        let root = directory.isEmpty ? "." : directory
        guard FileManager.default.fileExists(atPath: root + "/.git") else { return nil }

        let ignorePath = root + "/.gitignore"
        let entry = (envPath as NSString).lastPathComponent
        let current = (try? String(contentsOfFile: ignorePath, encoding: .utf8)) ?? ""
        let alreadyListed = current
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == entry }
        guard !alreadyListed else { return nil }

        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        let updated = current + separator + entry + "\n"
        guard (try? updated.write(toFile: ignorePath, atomically: true, encoding: .utf8)) != nil else {
            return "could not add '\(entry)' to \(ignorePath) — add it yourself before committing"
        }
        return "added '\(entry)' to \(ignorePath)"
    }

    private func runLogs(
        _ request: ProtocolRequest,
        services: [String],
        follow: Bool,
        tail: Int?,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName) else {
            onMessage(.errorMessage("failed to observe containers for project '\(projectName)'"))
            return 1
        }
        let targeted = services.isEmpty ? observed : observed.filter { services.contains($0.service) }
        guard !targeted.isEmpty else {
            onMessage(.errorMessage("no matching containers in project '\(projectName)'"))
            return 1
        }

        await withTaskGroup(of: Void.self) { group in
            for container in targeted {
                group.addTask {
                    try? await adapter.streamLogs(containerID: container.containerID, follow: follow, tail: tail) { line in
                        onMessage(.logMessage(service: container.service, line: line))
                    }
                }
            }
            await group.waitForAll()
        }
        return 0
    }

    private func runTop(_ request: ProtocolRequest, services: [String], onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName) else {
            onMessage(.errorMessage("failed to observe containers for project '\(projectName)'"))
            return 1
        }
        let targeted = services.isEmpty ? observed : observed.filter { services.contains($0.service) }
        guard !targeted.isEmpty else {
            onMessage(.errorMessage("no matching containers in project '\(projectName)'"))
            return 1
        }

        var succeeded = true
        for container in targeted.sorted(by: { $0.service < $1.service }) {
            do {
                let text = try await adapter.topProcesses(containerID: container.containerID)
                onMessage(.outputMessage(service: container.service, text: text))
            } catch {
                onMessage(.errorMessage("\(container.service): \(error)"))
                succeeded = false
            }
        }
        return succeeded ? 0 : 1
    }

    private func runStats(_ request: ProtocolRequest, services: [String], onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName) else {
            onMessage(.errorMessage("failed to observe containers for project '\(projectName)'"))
            return 1
        }
        let targeted = services.isEmpty ? observed : observed.filter { services.contains($0.service) }
        guard !targeted.isEmpty else {
            onMessage(.errorMessage("no matching containers in project '\(projectName)'"))
            return 1
        }

        do {
            let text = try await adapter.containerStats(containerIDs: targeted.map(\.containerID))
            onMessage(.outputMessage(text: text))
            return 0
        } catch {
            onMessage(.errorMessage("\(error)"))
            return 1
        }
    }

    private func runPort(
        _ request: ProtocolRequest,
        service: String,
        containerPort: Int,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName),
              let container = observed.first(where: { $0.service == service }) else {
            onMessage(.errorMessage("no container for service '\(service)' in project '\(projectName)'"))
            return 1
        }
        guard let binding = container.publishedPorts.first(where: { $0.containerPort == containerPort }) else {
            onMessage(.errorMessage("service '\(service)' does not publish container port \(containerPort)"))
            return 1
        }
        onMessage(ProtocolMessage(
            type: .container,
            service: service,
            container: container.containerID,
            project: projectName,
            image: container.image,
            ports: [binding.wireFormat]
        ))
        return 0
    }

    // MARK: - Direct-to-adapter: files

    private func runCp(
        _ request: ProtocolRequest,
        source: String,
        destination: String,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async -> Int32 {
        guard let resolvedSource = await resolveCopyEndpoint(source, request: request, onMessage: onMessage) else { return 1 }
        guard let resolvedDestination = await resolveCopyEndpoint(destination, request: request, onMessage: onMessage) else { return 1 }
        do {
            try await adapter.copyFile(source: resolvedSource, destination: resolvedDestination)
            onMessage(.resultMessage("copied \(source) -> \(destination)"))
            return 0
        } catch {
            onMessage(.errorMessage("\(error)"))
            return 1
        }
    }

    /// Rewrites a `service:path` endpoint to `containerID:path`, which is
    /// what `RuntimeAdapter.copyFile` documents as already-resolved. A path
    /// with no `service:` prefix — a plain host path — passes through
    /// unchanged.
    private func resolveCopyEndpoint(
        _ path: String,
        request: ProtocolRequest,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async -> String? {
        guard let colon = path.firstIndex(of: ":"), colon > path.startIndex else { return path }
        let serviceName = String(path[path.startIndex..<colon])
        let innerPath = String(path[path.index(after: colon)...])
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return nil }
        guard let observed = try? await adapter.observe(projectName: projectName),
              let container = observed.first(where: { $0.service == serviceName }) else {
            onMessage(.errorMessage("no container for service '\(serviceName)' in project '\(projectName)'"))
            return nil
        }
        return "\(container.containerID):\(innerPath)"
    }

    private func runExport(
        _ request: ProtocolRequest,
        service: String,
        outputPath: String,
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async -> Int32 {
        guard let projectName = resolveProjectName(request, onMessage: onMessage) else { return 1 }
        guard let observed = try? await adapter.observe(projectName: projectName),
              let container = observed.first(where: { $0.service == service }) else {
            onMessage(.errorMessage("no container for service '\(service)' in project '\(projectName)'"))
            return 1
        }
        do {
            try await adapter.exportContainer(containerID: container.containerID, to: outputPath)
            onMessage(.resultMessage("exported \(service) to \(outputPath)"))
            return 0
        } catch {
            onMessage(.errorMessage("\(error)"))
            return 1
        }
    }

    // MARK: - Watch

    /// Event-driven, not a fixed-tick poll: `DirectoryWatcher` (one per
    /// unique rule root, kqueue-backed) triggers a rescan on real filesystem
    /// activity, so nothing happens — no re-walk, no re-`stat` of every
    /// watched file — while the tree is idle. A periodic safety-net rescan
    /// (5s) still runs alongside it, since directory-level kqueue watching
    /// cannot see a rare same-inode in-place write with no rename; see
    /// `DirectoryWatcher`'s doc comment. Runs until the enclosing task is
    /// cancelled — the same "blocks until interrupted" shape as
    /// `logs --follow` — via `withTaskCancellationHandler`, since nothing
    /// else would otherwise wake the loop out of awaiting the next signal.
    ///
    /// This bypasses `Engine` deliberately: `up`'s reconciliation compares
    /// `configHash` (the service's *declared* config), which a `rebuild`
    /// here does not change — the point of a watch-triggered rebuild is a
    /// changed *image*, which `Reconciler` has no way to notice. Recreating
    /// the container directly, here, is what actually picks that up.
    private func runWatch(_ request: ProtocolRequest, services: [String], onMessage: @escaping @Sendable (ProtocolMessage) -> Void) async -> Int32 {
        guard let plan = resolvePlan(request, requestedServices: services, onMessage: onMessage) else { return 1 }
        guard let composeFilePath = request.composeFilePath else {
            onMessage(.errorMessage("watch requires --file"))
            return 1
        }
        let directory = URL(fileURLWithPath: composeFilePath).deletingLastPathComponent().path

        let watchable = plan.services.filter { !($0.develop?.watch ?? []).isEmpty }
        guard !watchable.isEmpty else {
            onMessage(.errorMessage("no requested service declares develop.watch"))
            return 1
        }

        onMessage(ProtocolMessage(type: .planned, services: watchable.map(\.name), waves: [watchable.map(\.name)]))

        guard let observed = try? await adapter.observe(projectName: plan.projectName) else {
            onMessage(.errorMessage("failed to observe containers for project '\(plan.projectName)'"))
            return 1
        }
        var containerByService: [String: String] = Dictionary(
            uniqueKeysWithValues: observed.filter { $0.running }.map { ($0.service, $0.containerID) }
        )

        var snapshots: [String: [String: Date]] = [:]
        for service in watchable {
            for rule in service.develop?.watch ?? [] {
                snapshots[watchKey(service: service.name, rule: rule)] = scanDirectory(rule.path, relativeTo: directory)
            }
        }

        let (wakeups, continuation) = AsyncStream<Void>.makeStream()

        var seenRoots: Set<String> = []
        var directoryWatchers: [DirectoryWatcher] = []
        for service in watchable {
            for rule in service.develop?.watch ?? [] {
                let root = watchRootURL(rule.path, relativeTo: directory).path
                guard seenRoots.insert(root).inserted else { continue }
                directoryWatchers.append(DirectoryWatcher(root: root) { continuation.yield(()) })
            }
        }

        let safetyNet = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continuation.yield(())
            }
        }

        await withTaskCancellationHandler {
            for await _ in wakeups {
                for service in watchable {
                    guard let containerID = containerByService[service.name] else { continue }
                    for rule in service.develop?.watch ?? [] {
                        let key = watchKey(service: service.name, rule: rule)
                        let previous = snapshots[key] ?? [:]
                        let current = scanDirectory(rule.path, relativeTo: directory)
                        snapshots[key] = current

                        let changes = WatchPlanner.diff(
                            previous: previous.mapValues { "\($0.timeIntervalSince1970)" },
                            current: current.mapValues { "\($0.timeIntervalSince1970)" }
                        )
                        let relevantPaths = changes
                            .filter { $0.kind != .removed && !WatchPlanner.isIgnored($0.path, by: rule) }
                            .map(\.path)
                        guard !relevantPaths.isEmpty, let action = rule.watchAction else { continue }

                        do {
                            if let newContainerID = try await applyWatchAction(
                                action, rule: rule, service: service, projectName: plan.projectName,
                                containerID: containerID, directory: directory, changedPaths: relevantPaths, onMessage: onMessage
                            ) {
                                containerByService[service.name] = newContainerID
                            }
                        } catch {
                            onMessage(.errorMessage("\(service.name): \(error)"))
                        }
                    }
                }
            }
        } onCancel: {
            // The only thing that can unblock `for await _ in wakeups` once
            // the task is cancelled: nothing else is watching for
            // cancellation, since the loop only wakes on an explicit yield.
            continuation.finish()
        }

        safetyNet.cancel()
        for watcher in directoryWatchers { watcher.stop() }
        return 0
    }

    private func watchKey(service: String, rule: WatchRule) -> String {
        "\(service)\u{0}\(rule.path)"
    }

    /// Applies one triggered watch rule. Returns the container's new ID when
    /// a rebuild recreated it (so the caller's tracking stays current), nil
    /// otherwise.
    private func applyWatchAction(
        _ action: WatchAction,
        rule: WatchRule,
        service: PlannedService,
        projectName: String,
        containerID: String,
        directory: String,
        changedPaths: [String],
        onMessage: @escaping @Sendable (ProtocolMessage) -> Void
    ) async throws -> String? {
        switch action {
        case .sync, .syncRestart:
            guard let target = rule.target else {
                onMessage(.errorMessage("\(service.name): watch rule for '\(rule.path)' needs a target for action '\(rule.action)'"))
                return nil
            }
            onMessage(ProtocolMessage(type: .serviceState, service: service.name, state: ServiceState.syncing.rawValue, detail: rule.path))
            let sourceRoot = watchRootURL(rule.path, relativeTo: directory).path
            for hostPath in changedPaths {
                var relative = String(hostPath.dropFirst(sourceRoot.count))
                if relative.hasPrefix("/") { relative.removeFirst() }
                let destination = target.hasSuffix("/") ? target + relative : target + "/" + relative
                try await adapter.copyFile(source: hostPath, destination: "\(containerID):\(destination)")
            }
            if action == .syncRestart {
                try await adapter.stopContainer(id: containerID)
                try await adapter.startContainer(id: containerID)
            }
            onMessage(ProtocolMessage(type: .serviceReady, service: service.name, container: containerID, reused: false))
            return nil

        case .rebuild:
            onMessage(ProtocolMessage(type: .serviceState, service: service.name, state: ServiceState.building.rawValue, detail: service.build?.context))
            let image = try await adapter.buildImage(for: service, projectName: projectName)
            onMessage(ProtocolMessage(type: .serviceState, service: service.name, state: ServiceState.recreating.rawValue, detail: "develop.watch rebuild"))
            try await adapter.stopContainer(id: containerID)
            try await adapter.deleteContainer(id: containerID, force: true)
            let newID = try await adapter.createContainer(for: service, image: image, projectName: projectName)
            try await adapter.startContainer(id: newID)
            onMessage(ProtocolMessage(type: .serviceReady, service: service.name, container: newID, reused: false))
            return newID
        }
    }

    /// Builds the absolute URL a `develop.watch` rule's `path` resolves to,
    /// normalized via `WatchPlanner.normalizedRulePath` first — see that
    /// function's doc comment for why the normalization has to happen before
    /// `appendingPathComponent`, not after.
    private func watchRootURL(_ relativePath: String, relativeTo directory: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent(WatchPlanner.normalizedRulePath(relativePath))
    }

    /// Recursively snapshots `relativePath` (relative to `directory`) as
    /// path -> modification time. Direct `FileManager` use, not routed
    /// through `ComposeFileProvider`: that protocol's contract is "read one
    /// compose-related file's contents," not "walk an arbitrary directory
    /// tree," and stretching it to cover watch's very different shape would
    /// make it serve two unrelated purposes.
    private func scanDirectory(_ relativePath: String, relativeTo directory: String) -> [String: Date] {
        let root = watchRootURL(relativePath, relativeTo: directory)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDirectory) else { return [:] }

        if !isDirectory.boolValue {
            let mtime = (try? fm.attributesOfItem(atPath: root.path))?[.modificationDate] as? Date
            return mtime.map { [root.path: $0] } ?? [:]
        }

        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else {
            return [:]
        }
        var result: [String: Date] = [:]
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory != true, let mtime = values.contentModificationDate else { continue }
            result[fileURL.path] = mtime
        }
        return result
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

    /// Same as `resolvePlan`, without emitting a message on failure — used by
    /// `runPassthrough`, which has no message stream to emit onto.
    private func resolvePlanPlain(_ request: ProtocolRequest, requestedServices: [String]) -> Plan? {
        guard let path = request.composeFilePath,
              let document = files.contents(atPath: path),
              let projectName = resolveProjectNamePlain(request) else { return nil }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let variables = resolveVariables(request, directory: directory)

        return try? Planner(files: files).plan(
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
    }

    private func resolveProjectName(_ request: ProtocolRequest, onMessage: @escaping @Sendable (ProtocolMessage) -> Void) -> String? {
        guard let name = resolveProjectNamePlain(request) else {
            onMessage(.errorMessage("a project name or a compose file is required"))
            return nil
        }
        return name
    }

    private func resolveProjectNamePlain(_ request: ProtocolRequest) -> String? {
        if let explicit = request.projectName { return explicit }
        guard let path = request.composeFilePath else { return nil }
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
