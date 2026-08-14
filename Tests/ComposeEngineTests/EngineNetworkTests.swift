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

    @Test("A project declaring no networks still gets one, and its services join it")
    func undeclaredNetworksFallBackToProjectDefault() async throws {
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

        // Not cosmetic parity with Compose: on this runtime a container left
        // on the built-in `default` network cannot have its ports published —
        // the host binds the port and even accepts a connection, but nothing
        // is proxied, so the app looks hung rather than unreachable.
        let networks = await adapter.ensuredNetworks
        #expect(networks == ["proj_default"])

        let web = try #require(result.service(named: "web"))
        #expect(web.networks == ["proj_default"])
    }

    @Test("A service naming its own network does not also join the default")
    func declaredNetworksSuppressTheDefault() throws {
        let result = try plan("""
            networks:
              backend: {}
            services:
              web:
                image: nginx
                networks: [backend]
            """)

        let web = try #require(result.service(named: "web"))
        #expect(web.networks == ["proj_backend"])
        // No stray empty network for a file that wired everything itself.
        #expect(result.networks.map(\.resolvedName) == ["proj_backend"])
    }

    @Test("A missing external volume fails the run instead of quietly getting an empty one")
    func missingExternalVolumeFails() async throws {
        let result = try plan("""
            volumes:
              archive:
                external: true
            services:
              web:
                image: nginx
                volumes:
                  - archive:/data
            """)
        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, _, _, let skipped) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        // The runtime invents an empty volume for an absent mount, so without
        // this check the run "succeeds" while handing back a blank disk where
        // the user's data was meant to be.
        #expect(!success)
        #expect(skipped == ["web"])

        let containers = await adapter.containers
        #expect(containers.isEmpty)

        let reasons = events.compactMap { event -> SkipReason? in
            guard case .serviceSkipped(_, let reason) = event else { return nil }
            return reason
        }
        #expect(reasons == [.volumeUnavailable])
    }

    @Test("down --remove deletes the networks this project created, but never its volumes")
    func downRemoveDeletesNetworksNotVolumes() async throws {
        let result = try plan("""
            networks:
              backend: {}
            volumes:
              data: {}
            services:
              web:
                image: nginx
                networks: [backend]
                volumes:
                  - data:/data
            """)
        let adapter = FakeRuntimeAdapter()
        _ = await Engine(adapter: adapter).up(result)

        let events = await Engine(adapter: adapter).down(projectName: "proj", remove: true)
        let removed = events.compactMap { event -> (ResourceKind, String)? in
            guard case .resourceRemoved(let kind, let name) = event else { return nil }
            return (kind, name)
        }
        #expect(removed.map(\.1) == ["proj_backend"])
        #expect(removed.allSatisfy { $0.0 == .network })
    }

    @Test("down --volumes deletes the volumes this project created")
    func downVolumesDeletesVolumes() async throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              web:
                image: nginx
                volumes:
                  - data:/data
            """)
        let adapter = FakeRuntimeAdapter()
        _ = await Engine(adapter: adapter).up(result)

        let events = await Engine(adapter: adapter).down(projectName: "proj", remove: true, volumes: true)
        let removed = events.compactMap { event -> (ResourceKind, String)? in
            guard case .resourceRemoved(let kind, let name) = event else { return nil }
            return (kind, name)
        }
        #expect(removed.contains { $0.0 == .volume && $0.1 == "proj_data" })
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
