//
//  NetworkLiveTests.swift
//  container-compose
//
//  Declared networks were planned but never created, so any compose file with
//  a non-external `networks:` block failed at container-create time. The fix
//  had a second half the in-memory fake could not see: a service's `networks:`
//  list holds compose-file KEYS, while the network is created under its
//  RESOLVED name (`backend` -> `proj_backend`). The fake accepted either, so
//  only a live daemon catches the mismatch — which is exactly what happened.
//
//  Requires: Apple's `container` CLI, running (`container system start`).
//  Skips itself when unavailable, matching the other live suites.
//

import Testing
import Foundation
import ComposeCore
import ComposeEngine
@testable import ComposeContainerRuntime

@Suite("Networks against a live daemon", .serialized)
struct NetworkLiveTests {

    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded ?? false
    }

    private func plan(_ document: String, projectName: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName)
        )
    }

    private func cleanUp(containerName: String, networkName: String) {
        _ = try? ContainerCLI.run(["stop", containerName])
        _ = try? ContainerCLI.run(["delete", "--force", containerName])
        LiveTeardown.removeNetwork(networkName)
    }

    @Test("A non-external network is created, and the service actually attaches to it")
    func createsNetworkAndAttachesService() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "ccnet\(UUID().uuidString.prefix(6).lowercased())"
        let containerName = "\(projectName)-web"
        let networkName = "\(projectName)_backend"
        cleanUp(containerName: containerName, networkName: networkName)
        defer { cleanUp(containerName: containerName, networkName: networkName) }

        let result = try plan("""
            networks:
              backend: {}
            services:
              web:
                image: nginx:alpine
                networks: [backend]
            """, projectName: projectName)

        let events = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        guard case .done(let success, let ready, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        // Before the fix this failed with "network backend not found": the
        // network existed, under a name the service never asked for.
        #expect(success)
        #expect(ready == ["web"])

        let created = events.contains {
            if case .networkReady(let name, let created) = $0 { return name == networkName && created }
            return false
        }
        #expect(created)

        // The network is really there, and really labelled as this project's,
        // which is what makes it identifiable as ours rather than pre-existing.
        let listed = try ContainerCLI.run(["network", "inspect", networkName])
        #expect(listed.succeeded)
        #expect(listed.stdout.contains(projectName))
    }

    @Test("An already-present network is reused rather than recreated")
    func existingNetworkIsReused() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "ccnet\(UUID().uuidString.prefix(6).lowercased())"
        let containerName = "\(projectName)-web"
        let networkName = "\(projectName)_backend"
        cleanUp(containerName: containerName, networkName: networkName)
        defer { cleanUp(containerName: containerName, networkName: networkName) }

        let document = """
            networks:
              backend: {}
            services:
              web:
                image: nginx:alpine
                networks: [backend]
            """
        let engine = Engine(adapter: ContainerRuntimeAdapter())
        _ = await engine.up(try plan(document, projectName: projectName))

        // Second run: the network exists now, so it must be reported as found,
        // not created — the same reconcile-don't-recreate rule the containers
        // follow.
        let events = await engine.up(try plan(document, projectName: projectName))
        let reusedNetwork = events.contains {
            if case .networkReady(let name, let created) = $0 { return name == networkName && !created }
            return false
        }
        #expect(reusedNetwork)
    }

    @Test("An uppercase project name still produces a network the runtime accepts")
    func uppercaseProjectNameProducesValidNetwork() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        // `--project MyApp`, or a directory named `MyApp`. The runtime rejects
        // an uppercase network name outright ("invalid network name"), so
        // without lowercasing the derived name this fails at create time —
        // the same trap that already bit build tags.
        let suffix = UUID().uuidString.prefix(6).lowercased()
        let projectName = "CCNet\(suffix)"
        let containerName = "\(projectName)-web"
        let networkName = "ccnet\(suffix)_backend"
        cleanUp(containerName: containerName, networkName: networkName)
        defer { cleanUp(containerName: containerName, networkName: networkName) }

        let result = try plan("""
            networks:
              backend: {}
            services:
              web:
                image: nginx:alpine
                networks: [backend]
            """, projectName: projectName)

        let planned = try #require(result.networks.first)
        #expect(planned.resolvedName == networkName)

        let events = await Engine(adapter: ContainerRuntimeAdapter()).up(result)
        guard case .done(let success, _, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)
    }

    @Test("An external network that does not exist fails before any container is created")
    func missingExternalNetworkFailsEarly() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "ccnet\(UUID().uuidString.prefix(6).lowercased())"
        let containerName = "\(projectName)-web"
        let absent = "ccnet-does-not-exist-\(UUID().uuidString.prefix(6))"
        defer { cleanUp(containerName: containerName, networkName: absent) }

        let result = try plan("""
            networks:
              missing:
                external: true
                name: \(absent)
            services:
              web:
                image: nginx:alpine
                networks: [missing]
            """, projectName: projectName)

        let events = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        guard case .done(let success, _, _, let skipped) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(!success)
        #expect(skipped == ["web"])

        // The failure names the network and says what to do about it, rather
        // than surfacing the runtime's bare "network not found" from a create
        // that should never have been attempted.
        let failure = events.compactMap { event -> String? in
            if case .networkFailed(_, let reason) = event { return reason }
            return nil
        }.first
        let reason = try #require(failure)
        #expect(reason.contains("declared external but does not exist"))

        // Nothing was created: no container should exist for this project.
        let observed = try await ContainerRuntimeAdapter().observe(projectName: projectName)
        #expect(observed.isEmpty)
    }
}
