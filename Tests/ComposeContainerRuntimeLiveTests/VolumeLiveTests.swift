//
//  VolumeLiveTests.swift
//  container-compose
//
//  A service's volume mount held the compose key while the declared volume was
//  namespaced per project, so every project using a common name like `db-data`
//  shared ONE volume. The in-memory fake cannot see this: it never attaches
//  storage, so both projects looked fine. Against a real daemon the second
//  project does not merely share the data — it fails to boot, with a
//  VZErrorDomain "storage device attachment is invalid" that names neither
//  volumes nor the project it collided with.
//
//  Requires: Apple's `container` CLI, running (`container system start`).
//  Skips itself when unavailable, matching the other live suites.
//

import Testing
import Foundation
import ComposeCore
import ComposeEngine
@testable import ComposeContainerRuntime

@Suite("Volumes against a live daemon", .serialized)
struct VolumeLiveTests {

    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded ?? false
    }

    private func plan(_ document: String, projectName: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName)
        )
    }

    private func cleanUp(projectNames: [String], volumeNames: [String]) {
        for project in projectNames {
            _ = try? ContainerCLI.run(["stop", "\(project)-box"])
            _ = try? ContainerCLI.run(["delete", "--force", "\(project)-box"])
        }
        for volume in volumeNames {
            _ = try? ContainerCLI.run(["volume", "delete", volume])
        }
    }

    @Test("Two projects sharing a volume name get separate volumes and both start")
    func sameVolumeNameDoesNotCollide() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let suffix = UUID().uuidString.prefix(6).lowercased()
        let one = "ccvola\(suffix)"
        let two = "ccvolb\(suffix)"
        let volumes = ["\(one)_app-data", "\(two)_app-data"]
        cleanUp(projectNames: [one, two], volumeNames: volumes)
        defer { cleanUp(projectNames: [one, two], volumeNames: volumes) }

        let document = """
            volumes:
              app-data: {}
            services:
              box:
                image: alpine:latest
                command: ["sleep", "120"]
                volumes:
                  - app-data:/shared
            """

        let engine = Engine(adapter: ContainerRuntimeAdapter())
        let first = await engine.up(try plan(document, projectName: one))
        guard case .done(let firstOK, _, _, _) = first.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(firstOK)

        // Before the fix this failed to bootstrap: the same volume was already
        // attached to the first project's running container.
        let second = await engine.up(try plan(document, projectName: two))
        guard case .done(let secondOK, _, let failed, _) = second.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(secondOK)
        #expect(failed.isEmpty)

        // Two real, distinct volumes — not one shared between the projects.
        let listed = try ContainerCLI.run(["volume", "list"])
        #expect(listed.stdout.contains(volumes[0]))
        #expect(listed.stdout.contains(volumes[1]))
    }

    @Test("A bind mount still resolves to the host path, not a namespaced volume")
    func bindMountIsNotNamespaced() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "ccbind\(UUID().uuidString.prefix(6).lowercased())"
        cleanUp(projectNames: [projectName], volumeNames: [])
        defer { cleanUp(projectNames: [projectName], volumeNames: []) }

        // A real directory with a real file, so a namespaced (and therefore
        // empty) volume would be visibly different from a working bind mount.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-bind-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "hello from the host".write(
            to: directory.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8
        )

        let result = try plan("""
            volumes:
              data: {}
            services:
              box:
                image: alpine:latest
                command: ["sleep", "120"]
                volumes:
                  - \(directory.path):/host
            """, projectName: projectName)

        // The mount must still name the host path verbatim.
        let box = try #require(result.service(named: "box"))
        #expect(box.volumes == ["\(directory.path):/host"])

        let events = await Engine(adapter: ContainerRuntimeAdapter()).up(result)
        guard case .done(let success, _, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)

        // And the host's file is really visible inside the container.
        let read = try ContainerCLI.run(["exec", "\(projectName)-box", "cat", "/host/marker.txt"])
        #expect(read.stdout.contains("hello from the host"))
    }
}
