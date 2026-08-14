//
//  ContainerRuntimeAdapter.swift
//  container-compose
//

import ComposeCore
import ComposeEngine
import Foundation

/// The `RuntimeAdapter` for Apple's `container` CLI.
///
/// Shells out rather than linking `ContainerAPIClient` (Apple's private Swift
/// package): it keeps this project's dependency graph to just Yams, and the
/// CLI's structured JSON output is a stable enough surface for what
/// reconciliation needs to observe.
public struct ContainerRuntimeAdapter: RuntimeAdapter {
    /// The label reconciliation reads back to decide whether a container's
    /// configuration still matches the plan. This is the entire mechanism —
    /// without it, every container looks like "unknown provenance" and gets
    /// recreated every time.
    public static let configHashLabel = "dev.container-compose.config-hash"

    /// Marks a container created by `runPassthrough` as NOT part of the
    /// managed, reconciled set — `listContainers` excludes anything carrying
    /// it. Without this, a `run` container (stamped with the same project and
    /// service labels as the real managed one, so a human inspecting it can
    /// still tell what it belongs to) would be indistinguishable from that
    /// managed container to `observe()`, and `ps`/`port`/`cp`/`export`/
    /// `Reconciler` could all pick the wrong one whenever both exist at once.
    public static let oneOffLabel = "com.docker.compose.oneoff"

    public init() {}

    // MARK: - Observation

    public func observe(projectName: String) async throws -> [ObservedContainer] {
        try listContainers().filter { $0.project == projectName }
    }

    public func observeAllProjects() async throws -> [ObservedContainer] {
        try listContainers()
    }

    /// Shared by both observation entry points: one `container ls` call,
    /// filtered to containers this tool manages (both compose labels
    /// present), with the project-scoping (or lack of it) left to the caller.
    private func listContainers() throws -> [ObservedContainer] {
        let result = try ContainerCLI.run(["ls", "--all", "--format", "json"])
        // An empty fleet prints "[]"; guard explicitly rather than letting an
        // empty stdout string fail JSON decoding and look like a real error.
        guard let data = result.stdout.data(using: .utf8), !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let entries = try JSONDecoder().decode([WireContainerEntry].self, from: data)

        return entries.compactMap { entry -> ObservedContainer? in
            let labels = entry.configuration.labels ?? [:]
            guard let project = labels["com.docker.compose.project"],
                  let service = labels["com.docker.compose.service"] else { return nil }
            guard labels[Self.oneOffLabel] != "True" else { return nil }
            return ObservedContainer(
                project: project,
                service: service,
                containerID: entry.configuration.id,
                running: entry.status.state == "running",
                configHash: labels[Self.configHashLabel],
                image: entry.configuration.image?.reference,
                publishedPorts: (entry.configuration.publishedPorts ?? []).map {
                    PublishedPort(containerPort: $0.containerPort, hostPort: $0.hostPort, hostAddress: $0.hostAddress)
                }
            )
        }
    }

    // MARK: - Images

    public func ensureImage(_ image: String) async throws {
        if try imageExists(image) { return }
        try ContainerCLI.run(["image", "pull", image])
    }

    private func imageExists(_ image: String) throws -> Bool {
        let result = try ContainerCLI.run(["image", "list", "--format", "json"])
        guard let data = result.stdout.data(using: .utf8), !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let entries = (try? JSONDecoder().decode([WireImageEntry].self, from: data)) ?? []
        // Matches on exact reference, a registry-qualified form of it
        // (`docker.io/library/nginx:latest` for `nginx:latest`), or the final
        // path component, since the runtime is not consistent about which
        // form it stores.
        return entries.contains { entry in
            entry.reference == image
                || entry.reference.hasSuffix("/\(image)")
                || entry.reference.components(separatedBy: "/").last == image
        }
    }

    // MARK: - Networks

    public func ensureNetwork(_ network: PlannedNetwork, projectName: String) async throws -> Bool {
        if try networkExists(network.resolvedName) { return false }

        // An external network is explicitly declared as not this project's to
        // manage, so creating one silently would be wrong twice over: it would
        // invent infrastructure the user said already existed, and it would
        // hide a genuine misconfiguration (a typo, or a stack that was never
        // brought up) behind a network with no containers on it.
        guard !network.external else {
            throw AdapterError.message(
                "network '\(network.resolvedName)' is declared external but does not exist — "
                    + "create it first (`container network create \(network.resolvedName)`), "
                    + "or drop `external: true` to have this project create it"
            )
        }

        // Labelled with the project so teardown can tell the networks this
        // project created apart from ones that merely happened to be present,
        // the same ownership rule the containers already follow.
        try ContainerCLI.run([
            "network", "create",
            "--label", "com.docker.compose.project=\(projectName)",
            network.resolvedName,
        ])
        return true
    }

    private func networkExists(_ name: String) throws -> Bool {
        let result = try ContainerCLI.run(["network", "list", "--format", "json"])
        guard let data = result.stdout.data(using: .utf8),
            !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return false
        }
        let entries = (try? JSONDecoder().decode([WireNetworkEntry].self, from: data)) ?? []
        return entries.contains { $0.configuration.name == name }
    }

    public func buildImage(for service: PlannedService, projectName: String) async throws -> String {
        guard let build = service.build else {
            throw AdapterError.message("service '\(service.name)' has no build configuration")
        }
        // The service's own `image:` names the tag when both are set
        // (Compose: build produces the image, image: names what to call it);
        // otherwise a deterministic project-scoped tag. Lowercased: an OCI
        // image reference's repository portion must be lowercase — an
        // uppercase project name (a directory named `MyApp`, or an explicit
        // `--project MyApp`) would otherwise make `container build --tag`
        // reject the reference outright. Compose itself lowercases derived
        // project names for the same reason; this reaches the same result
        // without constraining what `--project`/directory names may contain.
        let tag = service.image ?? "\(projectName.lowercased())/\(service.name.lowercased()):latest"

        var args = ["build", build.context, "--tag", tag]
        if let dockerfile = build.dockerfile { args.append(contentsOf: ["--file", dockerfile]) }
        if let target = build.target { args.append(contentsOf: ["--target", target]) }
        for (key, value) in build.args.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["--build-arg", "\(key)=\(value)"])
        }

        try ContainerCLI.run(args)
        return tag
    }

    public func pushImage(_ image: String) async throws {
        try ContainerCLI.run(["image", "push", image])
    }

    // MARK: - Lifecycle

    public func createContainer(for service: PlannedService, image: String, projectName: String) async throws -> String {
        let name = "\(projectName)-\(service.name)"
        var args = ["create", "--name", name, "-l", "com.docker.compose.project=\(projectName)", "-l", "com.docker.compose.service=\(service.name)"]
        args.append(contentsOf: ["-l", "\(Self.configHashLabel)=\(service.configHash)"])

        for (key, value) in service.environment.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        for port in service.ports { args.append(contentsOf: ["-p", port]) }
        for volume in service.volumes { args.append(contentsOf: ["-v", volume]) }
        for network in service.networks { args.append(contentsOf: ["--network", network]) }
        for (key, value) in service.labels.sorted(by: { $0.key < $1.key }) {
            // Compose-standard labels were already added above; anything else
            // here is a user-declared label, added without overriding those.
            guard key != "com.docker.compose.project", key != "com.docker.compose.service" else { continue }
            args.append(contentsOf: ["-l", "\(key)=\(value)"])
        }
        // Covers cap_add/cap_drop, dns*, init, tmpfs, ulimits, shm_size,
        // runtime, user, working_dir and platform — anything Core already
        // resolved into a runtime flag. Nothing service-specific needed here.
        for option in service.runtimeOptions {
            args.append(option.flag)
            if let value = option.value { args.append(value) }
        }

        args.append(image)
        if let command = service.command { args.append(contentsOf: command) }
        if let entrypoint = service.entrypoint, let first = entrypoint.first {
            args.append(contentsOf: ["--entrypoint", first])
        }

        try ContainerCLI.run(args)
        // `--name` makes the name the container's id, so there is no separate
        // id to parse out of stdout.
        return name
    }

    public func startContainer(id: String) async throws {
        try ContainerCLI.run(["start", id])
    }

    public func stopContainer(id: String) async throws {
        try ContainerCLI.run(["stop", id])
    }

    public func killContainer(id: String, signal: String) async throws {
        try ContainerCLI.run(["kill", "--signal", signal, id])
    }

    public func deleteContainer(id: String, force: Bool) async throws {
        var args = ["delete"]
        if force { args.append("--force") }
        args.append(id)
        try ContainerCLI.run(args)
    }

    // MARK: - Health

    public func waitForHealthy(containerID: String, healthcheck: PlannedHealthcheck?) async throws {
        guard let healthcheck, !healthcheck.disabled, !healthcheck.test.isEmpty else { return }

        let interval = healthcheck.interval ?? 30
        let retries = healthcheck.retries ?? 3
        let startPeriod = healthcheck.startPeriod ?? 0

        if startPeriod > 0 {
            try await Task.sleep(nanoseconds: UInt64(startPeriod * 1_000_000_000))
        }

        // Compose's `test` carries its own shape marker (`CMD` vs
        // `CMD-SHELL`) as the first element; strip it since `container exec`
        // just wants the argv to run.
        let command = healthcheck.test.first == "CMD-SHELL" || healthcheck.test.first == "CMD"
            ? Array(healthcheck.test.dropFirst())
            : healthcheck.test

        var attempt = 0
        while attempt < retries {
            if (try? ContainerCLI.run(["exec", containerID] + command)) != nil {
                return
            }
            attempt += 1
            if attempt < retries {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
        throw AdapterError.message("healthcheck did not pass after \(retries) attempt(s)")
    }

    // MARK: - Introspection

    public func topProcesses(containerID: String) async throws -> String {
        // `container` has no native `top`; this is `ps` run inside the
        // container. `-ef` first (most images), falling back to a bare `ps`
        // for BusyBox/distroless images that don't support the long form.
        if let result = try? ContainerCLI.run(["exec", containerID, "ps", "-ef"]), result.succeeded {
            return result.stdout
        }
        let fallback = try ContainerCLI.run(["exec", containerID, "ps"])
        return fallback.stdout
    }

    public func containerStats(containerIDs: [String]) async throws -> String {
        // --no-stream: a one-shot reading. Without it `container stats` never
        // returns, which would hang this call forever.
        let result = try ContainerCLI.run(["stats", "--no-stream"] + containerIDs)
        return result.stdout
    }

    // MARK: - Files

    public func copyFile(source: String, destination: String) async throws {
        try ContainerCLI.run(["copy", source, destination])
    }

    public func exportContainer(containerID: String, to outputPath: String) async throws {
        // `container export` refuses a running container ("container is not
        // stopped") — undocumented in `container export --help`, found live.
        // Absorbed here, not surfaced to callers: a user exporting a running
        // service's filesystem should not need to know this runtime quirk,
        // and should get the container back exactly as they left it
        // afterward — success or failure, via `defer`.
        let wasRunning = try listContainers().first { $0.containerID == containerID }?.running ?? false
        if wasRunning { try ContainerCLI.run(["stop", containerID]) }
        defer { if wasRunning { _ = try? ContainerCLI.run(["start", containerID]) } }
        try ContainerCLI.run(["export", "--output", outputPath, containerID])
    }

    // MARK: - Logs

    public func streamLogs(containerID: String, follow: Bool, tail: Int?, onLine: @escaping @Sendable (String) -> Void) async throws {
        var args = ["logs"]
        if follow { args.append("--follow") }
        if let tail { args.append(contentsOf: ["-n", "\(tail)"]) }
        args.append(containerID)

        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["container"] + args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Buffers partial reads across chunk boundaries so a line split by
        // the pipe's read granularity is delivered once, whole — chunk-level
        // delivery would hand `onLine` a fragment mid-message. The buffer is
        // lock-guarded because `readabilityHandler` fires on an arbitrary
        // dispatch queue, not this function's calling context.
        let buffer = LineBuffer()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            for line in buffer.append(chunk) { onLine(line) }
        }

        try process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        if let rest = buffer.flush(), !rest.isEmpty { onLine(rest) }
    }

    // MARK: - Interactive passthrough

    public func execPassthrough(containerID: String, command: [String], tty: Bool) async throws -> Int32 {
        var args = ["exec"]
        if tty { args.append(contentsOf: ["-i", "-t"]) }
        args.append(containerID)
        args.append(contentsOf: command)
        return runInheritingStdio(args)
    }

    public func runPassthrough(
        image: String,
        command: [String],
        environment: [String: String],
        workingDirectory: String?,
        labels: [String: String],
        remove: Bool,
        tty: Bool
    ) async throws -> Int32 {
        var args = ["run"]
        if remove { args.append("--rm") }
        if tty { args.append(contentsOf: ["-i", "-t"]) }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-e", "\(key)=\(value)"])
        }
        if let workingDirectory { args.append(contentsOf: ["--cwd", workingDirectory]) }
        // Stamped here, unconditionally, rather than left to the caller: every
        // `runPassthrough` invocation is one-off by definition (see the
        // protocol doc comment), so this invariant must not depend on every
        // call site remembering to set it.
        var allLabels = labels
        allLabels[Self.oneOffLabel] = "True"
        for (key, value) in allLabels.sorted(by: { $0.key < $1.key }) {
            args.append(contentsOf: ["-l", "\(key)=\(value)"])
        }
        args.append(image)
        args.append(contentsOf: command)
        return runInheritingStdio(args)
    }

    /// Runs `container` with the calling process's own stdio inherited —
    /// what makes an interactive session behave like one. Never throws on a
    /// non-zero exit: for `exec`/`run`, the child's exit code IS the answer,
    /// not an adapter-level failure.
    private func runInheritingStdio(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["container"] + arguments
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            return 127
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum AdapterError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self {
        case .message(let text): return text
        }
    }
}

/// Splits a byte stream into whole lines across chunk boundaries.
///
/// `FileHandle.readabilityHandler` fires on an arbitrary dispatch queue, so
/// the partial line has to be held somewhere concurrency-safe; a lock keeps
/// the handler synchronous rather than forcing it through an actor.
private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = Data()

    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        carry.append(chunk)

        var lines: [String] = []
        while let newline = carry.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = carry[carry.startIndex..<newline]
            carry = Data(carry[carry.index(after: newline)...])
            lines.append(String(data: Data(lineData), encoding: .utf8) ?? "")
        }
        return lines
    }

    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !carry.isEmpty else { return nil }
        let rest = String(data: carry, encoding: .utf8)
        carry = Data()
        return rest
    }
}
