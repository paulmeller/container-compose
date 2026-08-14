//
//  BuildLiveTests.swift
//  container-compose
//
//  Exercises ContainerRuntimeAdapter.buildImage against a real `container
//  build` invocation — args, a custom Dockerfile path, and multi-stage target
//  selection were all spot-checked by hand during development but never
//  captured as a durable regression test, unlike the reconciliation claim in
//  ReconciliationLiveTests.swift.
//
//  Requires: Apple's `container` CLI, running (`container system start`).
//  Skips itself when unavailable, matching ReconciliationLiveTests.
//

import Testing
import Foundation
import ComposeCore
import ComposeEngine
@testable import ComposeContainerRuntime

@Suite("Building images against a live daemon", .serialized)
struct BuildLiveTests {

    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded ?? false
    }

    private func withTempDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-build-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func plan(_ document: String, directory: String, projectName: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName, directory: directory)
        )
    }

    /// Builds `service`, creates and starts a container from the result
    /// (with `sleep 60` so it stays up long enough to exec into), reads
    /// `/marker` inside it, and tears everything down — the shared shape
    /// every test below needs to prove what the Dockerfile actually baked in.
    private func buildAndReadMarker(_ service: PlannedService, projectName: String, adapter: ContainerRuntimeAdapter) async throws -> String {
        let tag = try await adapter.buildImage(for: service, projectName: projectName)

        // These tests drive the adapter directly to exercise `build` on its
        // own, so the networks a plan implies are theirs to create — Engine is
        // what normally does that. Every service now joins `<project>_default`
        // when it names none of its own, so `create` would otherwise fail
        // against a network nobody made.
        for network in service.networks {
            _ = try? ContainerCLI.run(["network", "create", network])
        }

        let containerID = try await adapter.createContainer(for: service, image: tag, projectName: projectName)
        defer {
            _ = try? ContainerCLI.run(["stop", containerID])
            _ = try? ContainerCLI.run(["delete", "--force", containerID])
            _ = try? ContainerCLI.run(["image", "delete", tag])
            for network in service.networks {
                _ = try? ContainerCLI.run(["network", "delete", network])
            }
        }
        try await adapter.startContainer(id: containerID)
        let result = try ContainerCLI.run(["exec", containerID, "cat", "/marker"])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("buildImage builds a plain Dockerfile and tags it project/service:latest")
    func buildsAndTagsDefault() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        try await withTempDirectory { directory in
            try """
                FROM alpine:latest
                RUN echo hello-from-build > /marker
                """.write(to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
            let result = try plan("""
                services:
                  app:
                    build: .
                    command: ["sleep", "60"]
                """, directory: directory.path, projectName: projectName)
            let service = try #require(result.service(named: "app"))
            let adapter = ContainerRuntimeAdapter()

            let tag = try await adapter.buildImage(for: service, projectName: projectName)
            // Lowercased: an OCI reference's repository portion must be —
            // `projectName` here contains uppercase hex from UUID, which is
            // exactly the case (a mixed-case project name) that caught the
            // adapter bug this asserts against.
            #expect(tag == "\(projectName.lowercased())/app:latest")

            let marker = try await buildAndReadMarker(service, projectName: projectName, adapter: adapter)
            #expect(marker == "hello-from-build")
        }
    }

    @Test("buildImage passes build args through to the Dockerfile")
    func passesBuildArgs() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        try await withTempDirectory { directory in
            try """
                FROM alpine:latest
                ARG GREETING=default-value
                RUN echo $GREETING > /marker
                """.write(to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
            let result = try plan("""
                services:
                  app:
                    build:
                      context: .
                      args:
                        GREETING: custom-value
                    command: ["sleep", "60"]
                """, directory: directory.path, projectName: projectName)
            let service = try #require(result.service(named: "app"))
            let adapter = ContainerRuntimeAdapter()

            let marker = try await buildAndReadMarker(service, projectName: projectName, adapter: adapter)
            #expect(marker == "custom-value")
        }
    }

    @Test("buildImage honors a target stage in a multi-stage build")
    func honorsTargetStage() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        try await withTempDirectory { directory in
            try """
                FROM alpine:latest AS stage_a
                RUN echo from-stage-a > /marker
                FROM alpine:latest AS stage_b
                RUN echo from-stage-b > /marker
                """.write(to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
            let result = try plan("""
                services:
                  app:
                    build:
                      context: .
                      target: stage_a
                    command: ["sleep", "60"]
                """, directory: directory.path, projectName: projectName)
            let service = try #require(result.service(named: "app"))
            let adapter = ContainerRuntimeAdapter()

            let marker = try await buildAndReadMarker(service, projectName: projectName, adapter: adapter)
            #expect(marker == "from-stage-a", "target: stage_a must select that stage, not the last one in the file")
        }
    }

    @Test("buildImage honors a custom dockerfile: path, distinct from the default Dockerfile")
    func honorsCustomDockerfilePath() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        try await withTempDirectory { directory in
            try """
                FROM alpine:latest
                RUN echo from-default-dockerfile > /marker
                """.write(to: directory.appendingPathComponent("Dockerfile"), atomically: true, encoding: .utf8)

            let customDir = directory.appendingPathComponent("docker")
            try FileManager.default.createDirectory(at: customDir, withIntermediateDirectories: true)
            try """
                FROM alpine:latest
                RUN echo from-custom-dockerfile > /marker
                """.write(to: customDir.appendingPathComponent("Dockerfile.prod"), atomically: true, encoding: .utf8)

            let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
            let result = try plan("""
                services:
                  app:
                    build:
                      context: .
                      dockerfile: docker/Dockerfile.prod
                    command: ["sleep", "60"]
                """, directory: directory.path, projectName: projectName)
            let service = try #require(result.service(named: "app"))
            #expect(service.build?.dockerfile == directory.appendingPathComponent("docker/Dockerfile.prod").path)
            let adapter = ContainerRuntimeAdapter()

            let marker = try await buildAndReadMarker(service, projectName: projectName, adapter: adapter)
            #expect(marker == "from-custom-dockerfile")
        }
    }
}
