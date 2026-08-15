//
//  LeakLiveTests.swift
//  container-compose
//
//  `down --remove` promises to undo what `up` did. Nothing checked the
//  machine afterwards, so "undone" meant "the containers are gone" and
//  the project's network stayed — invisibly, because every teardown call
//  swallowed its failure.
//
//  That is not a tidiness problem. Each network is a launchd service the
//  daemon starts and waits on at boot, so an accumulated pile stops the
//  daemon coming up entirely, taking every running container with it.
//  This is the assertion that would have caught it on the first run
//  rather than after several hundred.
//

import Testing
import Foundation
@testable import ComposeCore
@testable import ComposeEngine
@testable import ComposeContainerRuntime

@Suite("Teardown leaves nothing behind")
struct LeakLiveTests {
    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded == true
    }

    /// What exists on the machine right now, by kind. Counted rather than
    /// listed: another suite may be running in parallel, so the assertion
    /// has to be about this project's own footprint returning to zero,
    /// not about the machine being identical.
    private func namesMatching(_ prefix: String) -> (networks: [String], volumes: [String], containers: [String]) {
        func lines(_ args: [String]) -> [String] {
            guard let result = try? ContainerCLI.run(args) else { return [] }
            return result.stdout
                .split(separator: "\n")
                .dropFirst()
                .compactMap { $0.split(separator: " ").first.map(String.init) }
                .filter { $0.lowercased().hasPrefix(prefix.lowercased()) }
        }
        return (
            lines(["network", "list"]),
            lines(["volume", "list"]),
            lines(["list", "--all"])
        )
    }

    @Test("up then down --remove leaves no container, network or volume behind")
    func downRemovesEverythingItCreated() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-leak-\(UUID().uuidString.prefix(8))"
        defer {
            // Belt and braces: if the assertion below fails, the test must
            // not itself leave the mess it is complaining about.
            LiveTeardown.removeProjectNetwork(projectName)
            ContainerCLI.attempt(
                ["delete", "--force", ProjectNaming.containerName(project: projectName, service: "app")],
                describedAs: "clean up after the leak test"
            )
            ContainerCLI.attempt(
                ["volume", "delete", ProjectNaming.volumeName(project: projectName, declared: "data")],
                describedAs: "clean up after the leak test"
            )
        }

        let before = namesMatching(projectName)
        #expect(before.networks.isEmpty && before.volumes.isEmpty && before.containers.isEmpty,
                "a project named \(projectName) already exists")

        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  app:
                    image: alpine:latest
                    command: ["sleep", "120"]
                    volumes:
                      - "data:/data"
                volumes:
                  data: {}
                """,
            options: PlanOptions(projectName: projectName)
        )

        let engine = Engine(adapter: ContainerRuntimeAdapter())
        let up = await engine.up(plan)
        guard case .done(let success, _, let failed, _) = up.last, success else {
            Issue.record("up failed: \(String(describing: up.last))")
            return
        }
        _ = failed

        // Everything the project asked for is really there — otherwise
        // "nothing left behind" afterwards would prove nothing.
        let created = namesMatching(projectName)
        #expect(created.containers.count == 1, "expected the service's container")
        #expect(created.networks.count == 1, "expected the project's default network")
        #expect(created.volumes.count == 1, "expected the project's volume")

        _ = await engine.down(projectName: projectName, remove: true, volumes: true)

        let after = namesMatching(projectName)
        #expect(after.containers.isEmpty, "containers left behind: \(after.containers)")
        // The one that leaked, once per test, for the life of the suite.
        #expect(after.networks.isEmpty, "networks left behind: \(after.networks)")
        #expect(after.volumes.isEmpty, "volumes left behind: \(after.volumes)")
    }

    @Test("down without --volumes keeps the data, which is the whole point of the flag")
    func downKeepsVolumesUnlessAsked() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-leak-\(UUID().uuidString.prefix(8))"
        defer {
            LiveTeardown.removeProjectNetwork(projectName)
            ContainerCLI.attempt(
                ["delete", "--force", ProjectNaming.containerName(project: projectName, service: "app")],
                describedAs: "clean up after the leak test"
            )
            ContainerCLI.attempt(
                ["volume", "delete", ProjectNaming.volumeName(project: projectName, declared: "data")],
                describedAs: "clean up after the leak test"
            )
        }

        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  app:
                    image: alpine:latest
                    command: ["sleep", "120"]
                    volumes:
                      - "data:/data"
                volumes:
                  data: {}
                """,
            options: PlanOptions(projectName: projectName)
        )

        let engine = Engine(adapter: ContainerRuntimeAdapter())
        _ = await engine.up(plan)
        _ = await engine.down(projectName: projectName, remove: true, volumes: false)

        let after = namesMatching(projectName)
        // A volume is the data itself; removing it on a plain `down` would
        // make the tidy-up assertion above dangerous rather than useful.
        #expect(after.volumes.count == 1, "a plain down must not delete data")
        #expect(after.containers.isEmpty)
        #expect(after.networks.isEmpty)
    }
}
