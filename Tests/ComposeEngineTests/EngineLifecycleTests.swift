//
//  EngineLifecycleTests.swift
//  container-compose
//
//  start/stop/restart/kill/rm/wait against the fake adapter — no daemon.
//

import Testing
import Foundation
import ComposeCore
import ComposeTestSupport
@testable import ComposeEngine

@Suite("Engine lifecycle operations")
struct EngineLifecycleTests {

    private func doneEvent(_ events: [EngineEvent]) -> (success: Bool, ready: [String], failed: [String], skipped: [String])? {
        guard case .done(let success, let ready, let failed, let skipped) = events.last else { return nil }
        return (success, ready, failed, skipped)
    }

    @Test("start only touches stopped containers, skipping ones already running")
    func startSkipsRunning() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "stopped-one", running: false, configHash: "h")
        await adapter.seed(id: "b", project: "proj", service: "already-running", running: true, configHash: "h")

        let events = await Engine(adapter: adapter).start(projectName: "proj")
        let done = try #require(doneEvent(events))

        #expect(done.ready == ["stopped-one"])
        #expect(done.skipped == ["already-running"])

        let containers = await adapter.containers
        #expect(containers["a"]?.running == true)
    }

    @Test("stop only touches running containers")
    func stopSkipsAlreadyStopped() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "running-one", running: true, configHash: "h")
        await adapter.seed(id: "b", project: "proj", service: "already-stopped", running: false, configHash: "h")

        let events = await Engine(adapter: adapter).stop(projectName: "proj")
        let done = try #require(doneEvent(events))

        #expect(done.ready == ["running-one"])
        #expect(done.skipped == ["already-stopped"])

        let containers = await adapter.containers
        #expect(containers["a"]?.running == false)
    }

    @Test("restart always acts, regardless of current state")
    func restartAlwaysActs() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "running", running: true, configHash: "h")
        await adapter.seed(id: "b", project: "proj", service: "stopped", running: false, configHash: "h")

        let events = await Engine(adapter: adapter).restart(projectName: "proj")
        let done = try #require(doneEvent(events))

        #expect(Set(done.ready) == ["running", "stopped"])
        #expect(done.skipped.isEmpty)

        let containers = await adapter.containers
        #expect(containers.values.allSatisfy { $0.running })
    }

    @Test("service filtering restricts the targeted set")
    func serviceFilteringRestrictsTarget() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: true, configHash: "h")
        await adapter.seed(id: "b", project: "proj", service: "db", running: true, configHash: "h")

        let events = await Engine(adapter: adapter).stop(projectName: "proj", services: ["web"])
        let done = try #require(doneEvent(events))

        #expect(done.ready == ["web"])
        #expect(done.skipped.isEmpty, "db was never targeted, so it must not appear as skipped either")

        let containers = await adapter.containers
        #expect(containers["a"]?.running == false)
        #expect(containers["b"]?.running == true, "an untargeted service must be untouched")
    }

    @Test("rm skips a running container unless forced")
    func rmSkipsRunningWithoutForce() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "running", running: true, configHash: "h")

        let events = await Engine(adapter: adapter).rm(projectName: "proj", force: false)
        let done = try #require(doneEvent(events))

        #expect(done.skipped == ["running"])
        let containers = await adapter.containers
        #expect(containers["a"] != nil, "must not remove a running container without --force")
    }

    @Test("rm --force stops then removes a running container")
    func rmForceRemovesRunning() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "running", running: true, configHash: "h")

        let events = await Engine(adapter: adapter).rm(projectName: "proj", force: true)
        let done = try #require(doneEvent(events))

        #expect(done.ready == ["running"])
        let containers = await adapter.containers
        #expect(containers["a"] == nil)
    }

    @Test("kill acts only on running containers")
    func killOnlyRunning() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "running", running: true, configHash: "h")
        await adapter.seed(id: "b", project: "proj", service: "stopped", running: false, configHash: "h")

        let events = await Engine(adapter: adapter).kill(projectName: "proj", signal: "TERM")
        let done = try #require(doneEvent(events))

        #expect(done.ready == ["running"])
        #expect(done.skipped == ["stopped"])
    }

    @Test("wait returns immediately when every target is already stopped")
    func waitReturnsImmediatelyWhenAlreadyStopped() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: false, configHash: "h")

        let events = await Engine(adapter: adapter).wait(projectName: "proj")
        let done = try #require(doneEvent(events))

        #expect(done.success)
        #expect(done.ready == ["web"])
    }

    @Test("wait times out and reports still-running services as failed")
    func waitTimesOut() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: true, configHash: "h")

        let events = await Engine(adapter: adapter).wait(projectName: "proj", timeoutSeconds: 0.1)
        let done = try #require(doneEvent(events))

        #expect(!done.success)
        #expect(done.failed == ["web"])
    }

    @Test("Engine.build builds only services with a build: config, skipping image-only ones")
    func buildOnlyBuildableServices() async throws {
        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  built:
                    build:
                      context: .
                  pulled:
                    image: alpine
                """,
            options: PlanOptions(projectName: "proj")
        )

        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).build(plan)
        let done = try #require(doneEvent(events))

        #expect(done.ready == ["built"])
        #expect(!done.ready.contains("pulled"), "a service with only image: has nothing to build")
    }

    @Test("Engine.build reports a build failure without touching containers")
    func buildFailureReported() async throws {
        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  broken:
                    build:
                      context: .
                """,
            options: PlanOptions(projectName: "proj")
        )

        let adapter = FakeRuntimeAdapter()
        await adapter.failBuild(forService: "broken")

        let events = await Engine(adapter: adapter).build(plan)
        let done = try #require(doneEvent(events))

        #expect(!done.success)
        #expect(done.failed == ["broken"])
    }
}
