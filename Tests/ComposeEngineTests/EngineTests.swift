//
//  EngineTests.swift
//  container-compose
//
//  Runs the real Engine against the in-memory FakeRuntimeAdapter — no daemon,
//  no containers, and (per test) milliseconds. This is what the adapter
//  boundary buys: Engine's actual orchestration code runs unmodified in
//  these tests.
//

import Testing
import Foundation
import ComposeCore
import ComposeTestSupport
@testable import ComposeEngine

@Suite("Engine.up")
struct EngineUpTests {

    private func plan(_ document: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "proj")
        )
    }

    @Test("A fresh project creates every service")
    func freshProjectCreatesEverything() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
              db: { image: postgres }
            """)
        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, let ready, let failed, let skipped) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success)
        #expect(Set(ready) == ["web", "db"])
        #expect(failed.isEmpty)
        #expect(skipped.isEmpty)

        let containers = await adapter.containers
        #expect(containers.values.allSatisfy { $0.running })
    }

    @Test("An already-correct, already-running service is reported reused and left alone")
    func unchangedServiceIsReused() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let hash = try #require(result.service(named: "web")).configHash

        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "existing-id", project: "proj", service: "web", running: true, configHash: hash)

        let events = await Engine(adapter: adapter).up(result)

        // This is the case delete-and-recreate cannot express: a ready event
        // with reused=true, and the SAME container id throughout — nothing
        // was stopped, deleted, or created.
        let readyEvents = events.compactMap { event -> (String, Bool)? in
            if case .serviceReady(let service, let id, let reused) = event { return (id, reused) }
            return nil
        }
        #expect(readyEvents.contains { $0.0 == "existing-id" && $0.1 == true })

        let containers = await adapter.containers
        #expect(containers.count == 1, "an unchanged service must not be deleted and recreated")
    }

    @Test("A stopped service with a matching hash is started, not recreated")
    func stoppedServiceIsStarted() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let hash = try #require(result.service(named: "web")).configHash

        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "existing-id", project: "proj", service: "web", running: false, configHash: hash)

        _ = await Engine(adapter: adapter).up(result)

        let containers = await adapter.containers
        #expect(containers.count == 1, "starting must not create a second container")
        #expect(containers["existing-id"]?.running == true)
    }

    @Test("A changed service is recreated under a new container id")
    func changedServiceIsRecreated() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)

        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "old-id", project: "proj", service: "web", running: true, configHash: "stale")

        _ = await Engine(adapter: adapter).up(result)

        let containers = await adapter.containers
        #expect(containers["old-id"] == nil, "the stale container must be removed")
        #expect(containers.count == 1, "exactly one replacement container must exist")
        #expect(containers.values.first?.running == true)
    }

    @Test("Waves execute in order: a dependency is up before its dependent starts")
    func wavesExecuteInOrder() async throws {
        let result = try plan("""
            services:
              db: { image: postgres }
              api:
                image: alpine
                depends_on: [db]
            """)
        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).up(result)

        let readyOrder = events.compactMap { event -> String? in
            if case .serviceReady(let service, _, _) = event { return service }
            return nil
        }
        let dbIndex = try #require(readyOrder.firstIndex(of: "db"))
        let apiIndex = try #require(readyOrder.firstIndex(of: "api"))
        #expect(dbIndex < apiIndex)
    }

    @Test("A failed service causes its dependents to be reported skipped, not failed")
    func downstreamServicesAreSkippedNotFailed() async throws {
        let result = try plan("""
            services:
              db: { image: postgres }
              api:
                image: alpine
                depends_on: [db]
              web:
                image: nginx
                depends_on: [api]
            """)

        let adapter = FakeRuntimeAdapter()
        await adapter.failCreate(forService: "db")

        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, let ready, let failed, let skipped) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(!success)
        #expect(failed == ["db"])
        // api and web never ran at all — this is the distinction the design
        // thesis names explicitly: "never attempted" must not look identical
        // to "attempted and failed".
        #expect(Set(skipped) == ["api", "web"])
        #expect(ready.isEmpty)

        let skipEvents = events.compactMap { event -> (String, SkipReason)? in
            if case .serviceSkipped(let service, let reason) = event { return (service, reason) }
            return nil
        }
        #expect(Set(skipEvents.map(\.0)) == ["api", "web"])
        #expect(skipEvents.allSatisfy { $0.1 == .dependencyFailed })
    }

    @Test("An independent service still succeeds when an unrelated one fails")
    func independentServiceSucceedsDespiteUnrelatedFailure() async throws {
        let result = try plan("""
            services:
              broken: { image: nginx }
              fine: { image: alpine }
            """)

        let adapter = FakeRuntimeAdapter()
        await adapter.failCreate(forService: "broken")

        let events = await Engine(adapter: adapter).up(result)

        guard case .done(_, let ready, let failed, let skipped) = events.last else {
            Issue.record("expected .done")
            return
        }
        // Both are in the same wave (no dependency between them), so
        // "broken" failing must not prevent "fine" from succeeding.
        #expect(ready == ["fine"])
        #expect(failed == ["broken"])
        #expect(skipped.isEmpty)
    }

    @Test("done is emitted exactly once, on both success and failure")
    func doneIsAlwaysEmittedExactlyOnce() async throws {
        let succeeding = try plan("""
            services:
              web: { image: nginx }
            """)
        let succeedEvents = await Engine(adapter: FakeRuntimeAdapter()).up(succeeding)
        #expect(succeedEvents.filter { if case .done = $0 { return true }; return false }.count == 1)

        let failing = try plan("""
            services:
              web: { image: nginx }
            """)
        let failAdapter = FakeRuntimeAdapter()
        await failAdapter.failCreate(forService: "web")
        let failEvents = await Engine(adapter: failAdapter).up(failing)
        #expect(failEvents.filter { if case .done = $0 { return true }; return false }.count == 1)
    }

    @Test("planned is emitted first and names every service up front")
    func plannedEventIsFirst() async throws {
        let result = try plan("""
            services:
              db: { image: postgres }
              api:
                image: alpine
                depends_on: [db]
            """)
        let events = await Engine(adapter: FakeRuntimeAdapter()).up(result)

        guard case .planned(let services, let waves) = events.first else {
            Issue.record("expected .planned as the first event")
            return
        }
        #expect(Set(services) == ["db", "api"])
        #expect(waves == [["db"], ["api"]])
    }
}

@Suite("Engine.down")
struct EngineDownTests {

    @Test("down stops every observed container for the project")
    func downStopsEverything() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "web-id", project: "proj", service: "web", running: true, configHash: "h1")
        await adapter.seed(id: "db-id", project: "proj", service: "db", running: true, configHash: "h2")

        let events = await Engine(adapter: adapter).down(projectName: "proj", remove: false)

        guard case .done(let success, let ready, _, _) = events.last else {
            Issue.record("expected .done")
            return
        }
        #expect(success)
        #expect(Set(ready) == ["web", "db"])

        // Regression: a container that survives `down` (no --remove) must be
        // reported as stopped, not as "ready" — it is not running.
        let stoppedEvents = events.compactMap { event -> String? in
            if case .serviceStopped(let service, _) = event { return service }
            return nil
        }
        #expect(Set(stoppedEvents) == ["web", "db"])
        #expect(!events.contains { if case .serviceReady = $0 { return true }; return false })

        let containers = await adapter.containers
        #expect(containers.count == 2, "without remove:true, containers must still exist")
        #expect(containers.values.allSatisfy { !$0.running })
    }

    @Test("down with remove:true deletes containers and reports serviceRemoved")
    func downWithRemoveDeletesContainers() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "web-id", project: "proj", service: "web", running: true, configHash: "h1")

        let events = await Engine(adapter: adapter).down(projectName: "proj", remove: true)

        let removedEvents = events.compactMap { event -> String? in
            if case .serviceRemoved(let service, _) = event { return service }
            return nil
        }
        #expect(removedEvents == ["web"])
        #expect(!events.contains { if case .serviceStopped = $0 { return true }; return false }, "removed, not merely stopped")

        let containers = await adapter.containers
        #expect(containers.isEmpty, "down --remove must be the ONLY path that deletes")
    }

    @Test("down on a project with no containers succeeds trivially")
    func downOnEmptyProject() async throws {
        let events = await Engine(adapter: FakeRuntimeAdapter()).down(projectName: "nothing-here", remove: true)

        guard case .done(let success, let ready, let failed, _) = events.last else {
            Issue.record("expected .done")
            return
        }
        #expect(success)
        #expect(ready.isEmpty)
        #expect(failed.isEmpty)
    }
}
