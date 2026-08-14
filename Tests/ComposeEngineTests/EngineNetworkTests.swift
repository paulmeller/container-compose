//
//  EngineNetworkTests.swift
//  container-compose
//
//  Networks declared in a compose file were planned but never created, so any
//  file with a non-external `networks:` block failed at container-create time
//  against a network that did not exist. These tests pin the fix: Engine
//  ensures every planned network before the first wave, external networks are
//  never created (only required to already exist), and a network that cannot
//  be made available fails the run before any container is touched.
//

import Testing
import Foundation
import ComposeCore
import ComposeTestSupport
@testable import ComposeEngine

@Suite("Engine network setup")
struct EngineNetworkTests {

    private func plan(_ document: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "proj")
        )
    }

    @Test("A non-external network is created before any container is")
    func createsDeclaredNetwork() async throws {
        let result = try plan("""
            networks:
              backend: {}
            services:
              web:
                image: nginx
                networks: [backend]
            """)
        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, let ready, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)
        #expect(ready == ["web"])

        let networks = await adapter.ensuredNetworks
        #expect(networks == ["proj_backend"])
    }

    @Test("An external network is required, never created")
    func externalNetworkIsNotCreated() async throws {
        let result = try plan("""
            networks:
              shared:
                external: true
            services:
              web:
                image: nginx
                networks: [shared]
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.seedNetwork("shared")
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, _, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)

        // Present already, so ensuring it must not have created anything.
        let created = await adapter.createdNetworks
        #expect(created.isEmpty)
    }

    @Test("A network that cannot be made available fails the run before any container is created")
    func networkFailureSkipsEveryService() async throws {
        let result = try plan("""
            networks:
              backend: {}
            services:
              web:
                image: nginx
                networks: [backend]
              db:
                image: postgres
                networks: [backend]
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.failNetwork("proj_backend")
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, let ready, _, let skipped) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(!success)
        #expect(ready.isEmpty)
        #expect(Set(skipped) == ["web", "db"])

        // The whole point of failing early: nothing was created.
        let containers = await adapter.containers
        #expect(containers.isEmpty)

        let reasons = events.compactMap { event -> SkipReason? in
            guard case .serviceSkipped(_, let reason) = event else { return nil }
            return reason
        }
        #expect(reasons.allSatisfy { $0 == .networkUnavailable })
    }

    @Test("A service's network references resolve to the same names the networks are created under")
    func serviceNetworkNamesMatchCreatedNetworks() async throws {
        let result = try plan("""
            networks:
              backend: {}
              shared:
                external: true
                name: shared-net
            services:
              web:
                image: nginx
                networks: [backend, shared]
            """)

        // The bug this pins: the top-level block created `proj_backend` while
        // the service still asked the runtime for `backend`, so `create`
        // failed against a network that existed under another name. Whatever a
        // service references MUST be a name the project actually creates or
        // requires.
        let web = try #require(result.service(named: "web"))
        let created = Set(result.networks.map(\.resolvedName))
        #expect(Set(web.networks) == created)
        #expect(Set(web.networks) == ["proj_backend", "shared-net"])
    }

    @Test("A project declaring no networks ensures none, and still comes up")
    func noDeclaredNetworksIsUntouched() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, _, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)

        let networks = await adapter.ensuredNetworks
        #expect(networks.isEmpty)
    }

    @Test("An already-present non-external network is reused, not recreated")
    func existingNetworkIsReused() async throws {
        let result = try plan("""
            networks:
              backend: {}
            services:
              web:
                image: nginx
                networks: [backend]
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.seedNetwork("proj_backend")
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, _, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)

        let created = await adapter.createdNetworks
        #expect(created.isEmpty)
    }
}
