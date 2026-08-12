//
//  ObservationLiveTests.swift
//  container-compose
//
//  Covers the adapter methods behind ps/ls/port, top/stats, logs, exec, and
//  cp/export — all spot-checked by hand against the real daemon during
//  development (via the CLI directly) but, unlike reconciliation and build,
//  never captured as a durable regression test until now.
//
//  Requires: Apple's `container` CLI, running (`container system start`).
//  Skips itself when unavailable, matching ReconciliationLiveTests.
//

import Testing
import Foundation
import ComposeCore
import ComposeEngine
@testable import ComposeContainerRuntime

@Suite("Observation and introspection against a live daemon", .serialized)
struct ObservationLiveTests {

    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded ?? false
    }

    private func plan(_ document: String, projectName: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName)
        )
    }

    private func cleanUp(containerName: String) {
        _ = try? ContainerCLI.run(["stop", containerName])
        _ = try? ContainerCLI.run(["delete", "--force", containerName])
    }

    @Test("observe() reports the real image reference and published port binding")
    func observeReportsImageAndPorts() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-web"
        cleanUp(containerName: containerName)
        defer { cleanUp(containerName: containerName) }

        let result = try plan("""
            services:
              web:
                image: nginx:alpine
                ports:
                  - "18099:80"
            """, projectName: projectName)
        _ = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        let observed = try await ContainerRuntimeAdapter().observe(projectName: projectName)
        let web = try #require(observed.first { $0.service == "web" })

        #expect(web.running)
        #expect(web.image?.contains("nginx") == true)
        let binding = try #require(web.publishedPorts.first { $0.containerPort == 80 })
        #expect(binding.hostPort == 18099)
    }

    @Test("topProcesses and containerStats return real, non-empty runtime-formatted text")
    func topAndStatsReturnRealText() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName)
        defer { cleanUp(containerName: containerName) }

        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "60"]
            """, projectName: projectName)
        _ = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        let adapter = ContainerRuntimeAdapter()
        let top = try await adapter.topProcesses(containerID: containerName)
        #expect(top.contains("sleep"), "the running command must show up in the process listing")

        let stats = try await adapter.containerStats(containerIDs: [containerName])
        #expect(!stats.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test("streamLogs replays a running container's real log output")
    func streamLogsReplaysRealOutput() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName)
        defer { cleanUp(containerName: containerName) }

        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sh", "-c", "echo marker-line-from-live-test; sleep 60"]
            """, projectName: projectName)
        _ = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        let lines = LineCollector()
        try await ContainerRuntimeAdapter().streamLogs(containerID: containerName, follow: false, tail: nil) { line in
            lines.append(line)
        }
        #expect(lines.all.contains { $0.contains("marker-line-from-live-test") })
    }

    @Test("execPassthrough returns the real exit code of the command it ran, success and failure")
    func execPassthroughReturnsRealExitCodes() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName)
        defer { cleanUp(containerName: containerName) }

        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "60"]
            """, projectName: projectName)
        _ = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        let adapter = ContainerRuntimeAdapter()
        let success = try await adapter.execPassthrough(containerID: containerName, command: ["true"], tty: false)
        #expect(success == 0)

        let failure = try await adapter.execPassthrough(containerID: containerName, command: ["false"], tty: false)
        #expect(failure != 0)
    }

    @Test("copyFile and exportContainer perform real file operations against a running container")
    func copyAndExportPerformRealFileOperations() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName)
        defer { cleanUp(containerName: containerName) }

        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "60"]
            """, projectName: projectName)
        _ = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        let adapter = ContainerRuntimeAdapter()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("cc-copy-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let copiedPath = tempDir.appendingPathComponent("hostname").path
        try await adapter.copyFile(source: "\(containerName):/etc/hostname", destination: copiedPath)
        #expect(FileManager.default.fileExists(atPath: copiedPath))
        let copiedContents = try String(contentsOfFile: copiedPath, encoding: .utf8)
        #expect(!copiedContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let exportPath = tempDir.appendingPathComponent("export.tar").path
        try await adapter.exportContainer(containerID: containerName, to: exportPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: exportPath)
        let size = attributes[.size] as? Int ?? 0
        #expect(size > 0, "an exported container filesystem must not be an empty archive")
    }
}

/// Lock-guarded because `streamLogs`'s `onLine` may fire from a background
/// dispatch queue — same reasoning as `LineBuffer` in the real adapter.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        lines.append(line)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
