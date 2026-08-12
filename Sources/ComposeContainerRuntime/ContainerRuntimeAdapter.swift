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

    public init() {}

    // MARK: - Observation

    public func observe(projectName: String) async throws -> [ObservedContainer] {
        let result = try ContainerCLI.run(["ls", "--all", "--format", "json"])
        // An empty fleet prints "[]"; guard explicitly rather than letting an
        // empty stdout string fail JSON decoding and look like a real error.
        guard let data = result.stdout.data(using: .utf8), !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let entries = try JSONDecoder().decode([WireContainerEntry].self, from: data)

        return entries.compactMap { entry -> ObservedContainer? in
            let labels = entry.configuration.labels ?? [:]
            guard labels["com.docker.compose.project"] == projectName,
                  let service = labels["com.docker.compose.service"] else { return nil }
            return ObservedContainer(
                service: service,
                containerID: entry.configuration.id,
                running: entry.status.state == "running",
                configHash: labels[Self.configHashLabel]
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
        // path component — the same three-way check the fork's tooling used,
        // since the runtime is not consistent about which form it stores.
        return entries.contains { entry in
            entry.reference == image
                || entry.reference.hasSuffix("/\(image)")
                || entry.reference.components(separatedBy: "/").last == image
        }
    }

    // MARK: - Lifecycle

    public func createContainer(for service: PlannedService, projectName: String) async throws -> String {
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

        guard let image = service.image else {
            // A build-only service with no image yet — building is a
            // separate concern from creating; the plan carries `build` for
            // whatever builds it before this is called.
            throw ContainerCLI.Failure.launchFailed(
                command: args,
                underlying: NSError(domain: "ContainerRuntimeAdapter", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "service '\(service.name)' has no image to create from (build is not yet wired into this adapter)"
                ])
            )
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
        throw ContainerCLI.Failure.launchFailed(
            command: ["exec", containerID] + command,
            underlying: NSError(domain: "ContainerRuntimeAdapter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "healthcheck did not pass after \(retries) attempt(s)"
            ])
        )
    }
}
