//
//  ReconciliationLiveTests.swift
//  container-compose
//
//  Runs Engine against the REAL ContainerRuntimeAdapter and a live `container`
//  daemon. This is the one place in the whole project where a wrong
//  assumption about the runtime's actual behavior could hide, because
//  everything upstream is proven against fakes.
//
//  Requires: Apple's `container` CLI, running (`container system start`).
//  Skips itself when unavailable rather than failing CI environments that
//  don't have the runtime.
//

import Testing
import Foundation
import ComposeCore
import ComposeEngine
@testable import ComposeContainerRuntime

@Suite("Reconciliation against a live daemon", .serialized)
struct ReconciliationLiveTests {

    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded ?? false
    }

    private func plan(_ document: String, projectName: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName)
        )
    }

    /// Best-effort teardown, run before and after each test so a prior failed
    /// run never contaminates the next one.
    /// Also removes the project's default network.
    ///
    /// Deleting only the container left `<project>_default` behind on
    /// every run — the pile that eventually wedged the runtime, because
    /// each network is a launchd service the daemon waits on at boot.
    /// Scoped to this test's own project rather than swept by prefix:
    /// these suites run in parallel, and a sweep could take a network a
    /// concurrent test was still setting up.
    private func cleanUp(containerName: String, projectName: String? = nil) {
        _ = try? ContainerCLI.run(["stop", containerName])
        _ = try? ContainerCLI.run(["delete", "--force", containerName])
        if let projectName {
            LiveTeardown.removeProjectNetwork(projectName)
        }
    }

    @Test("A fresh service is created and reaches running")
    func createsAndStarts() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName, projectName: projectName)
        defer { cleanUp(containerName: containerName, projectName: projectName) }

        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
            """, projectName: projectName)

        let events = await Engine(adapter: ContainerRuntimeAdapter()).up(result)

        guard case .done(let success, let ready, let failed, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        #expect(success, "up failed: \(failed)")
        #expect(ready == ["app"])

        let readyEvent = events.compactMap { event -> (String, Bool)? in
            if case .serviceReady(let service, let id, let reused) = event, service == "app" { return (id, reused) }
            return nil
        }.first
        #expect(readyEvent?.0 == containerName)
        #expect(readyEvent?.1 == false, "a freshly created container must not report reused=true")
    }

    @Test("Running up again against an unchanged plan reuses the container rather than recreating it")
    func secondRunReusesRatherThanRecreates() async throws {
        // This is the specific, load-bearing claim of the whole project: an
        // already-correct, already-running container survives a second `up`
        // untouched. A delete-and-recreate implementation fails this test.
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName, projectName: projectName)
        defer { cleanUp(containerName: containerName, projectName: projectName) }

        let document = """
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
            """
        let result = try plan(document, projectName: projectName)
        let adapter = ContainerRuntimeAdapter()

        let firstRun = await Engine(adapter: adapter).up(result)
        guard case .done(let firstSuccess, _, _, _) = firstRun.last, firstSuccess else {
            Issue.record("first up did not succeed: \(firstRun)")
            return
        }

        // Fresh Plan and fresh Engine, exactly as a new process invocation
        // would produce — nothing carried over in memory between "runs".
        let secondPlanResult = try plan(document, projectName: projectName)
        let secondRun = await Engine(adapter: ContainerRuntimeAdapter()).up(secondPlanResult)

        guard case .done(let secondSuccess, let ready, let failed, _) = secondRun.last else {
            Issue.record("expected a terminal .done event on the second run")
            return
        }
        #expect(secondSuccess, "second up failed: \(failed)")
        #expect(ready == ["app"])

        let secondReadyEvent = secondRun.compactMap { event -> (String, Bool)? in
            if case .serviceReady(let service, let id, let reused) = event, service == "app" { return (id, reused) }
            return nil
        }.first
        #expect(secondReadyEvent?.0 == containerName, "the SAME container name must be reported both times")
        #expect(secondReadyEvent?.1 == true, "the second run must report reused=true — this is the whole point")

        // No .creating/.pulling/.recreating events on the second run: nothing
        // about container lifecycle should have happened at all.
        let secondRunStates = secondRun.compactMap { event -> ServiceState? in
            if case .serviceState(_, let state, _) = event { return state }
            return nil
        }
        #expect(!secondRunStates.contains(.recreating), "an unchanged service must never be recreated")
        #expect(!secondRunStates.contains(.creating), "an unchanged service must never be created a second time")

        // Confirm directly against the daemon too, not just the event stream:
        // exactly one container with this name exists.
        let listing = try ContainerCLI.run(["ls", "--all"])
        let matches = listing.stdout.components(separatedBy: "\n").filter { $0.contains(containerName) }
        #expect(matches.count == 1, "exactly one container should exist, found: \(matches)")
    }

    @Test("A changed service is recreated, and the change is observable")
    func changedServiceIsRecreated() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName, projectName: projectName)
        defer { cleanUp(containerName: containerName, projectName: projectName) }

        let adapter = ContainerRuntimeAdapter()

        let firstPlan = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
                environment:
                  MARKER: original
            """, projectName: projectName)
        let firstRun = await Engine(adapter: adapter).up(firstPlan)
        guard case .done(let firstSuccess, _, _, _) = firstRun.last, firstSuccess else {
            Issue.record("first up did not succeed: \(firstRun)")
            return
        }

        // A genuinely different plan: the environment value changed, which
        // changes configHash even though the document's shape is identical.
        let secondPlan = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
                environment:
                  MARKER: changed
            """, projectName: projectName)
        let secondRun = await Engine(adapter: ContainerRuntimeAdapter()).up(secondPlan)

        guard case .done(let secondSuccess, _, let failed, _) = secondRun.last else {
            Issue.record("expected .done")
            return
        }
        #expect(secondSuccess, "recreate run failed: \(failed)")

        let secondReadyEvent = secondRun.compactMap { event -> Bool? in
            if case .serviceReady(let service, _, let reused) = event, service == "app" { return reused }
            return nil
        }.first
        #expect(secondReadyEvent == false, "a changed service must be reported as NOT reused")

        // The running container now carries the new value — proof the
        // replacement is not just reported but real.
        let inspected = try ContainerCLI.run(["exec", containerName, "sh", "-c", "echo $MARKER"])
        #expect(inspected.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "changed")
    }

    @Test("down removes the container, and a subsequent up creates fresh")
    func downThenUpCreatesFresh() async throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName, projectName: projectName)
        defer { cleanUp(containerName: containerName, projectName: projectName) }

        let adapter = ContainerRuntimeAdapter()
        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
            """, projectName: projectName)

        _ = await Engine(adapter: adapter).up(result)
        let downEvents = await Engine(adapter: adapter).down(projectName: projectName, remove: true)

        guard case .done(let downSuccess, _, _, _) = downEvents.last else {
            Issue.record("expected .done from down")
            return
        }
        #expect(downSuccess)

        let listing = try ContainerCLI.run(["ls", "--all"])
        #expect(!listing.stdout.contains(containerName), "down --remove must leave no trace")

        // Up again: since nothing is observed now, this must be a genuine
        // create, not a "reused" — proving `down` really did remove it rather
        // than the adapter reporting success without effect.
        let upAgain = await Engine(adapter: adapter).up(try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
            """, projectName: projectName))

        let reused = upAgain.compactMap { event -> Bool? in
            if case .serviceReady(let service, _, let reused) = event, service == "app" { return reused }
            return nil
        }.first
        #expect(reused == false)
    }

    @Test("A runPassthrough container is invisible to observe(), even though it shares the managed container's labels")
    func runPassthroughContainerIsExcludedFromObserve() async throws {
        // Regression: caught live — `run web ...` stamped the SAME project +
        // service labels as the real managed "web" container, so `observe()`
        // returned both, and callers like `export`/`cp`/`port` (which just
        // take `.first(where: { $0.service == name })`) could resolve to
        // whichever one the runtime happened to list first — including the
        // one-off container after `--rm` had already deleted it.
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }

        let projectName = "cc-live-\(UUID().uuidString.prefix(8))"
        let containerName = "\(projectName)-app"
        cleanUp(containerName: containerName, projectName: projectName)
        defer { cleanUp(containerName: containerName, projectName: projectName) }

        let adapter = ContainerRuntimeAdapter()
        let result = try plan("""
            services:
              app:
                image: alpine:latest
                command: ["sleep", "120"]
            """, projectName: projectName)
        _ = await Engine(adapter: adapter).up(result)

        let exitCode = try await adapter.runPassthrough(
            image: "alpine:latest",
            command: ["true"],
            environment: [:],
            workingDirectory: nil,
            labels: ["com.docker.compose.project": projectName, "com.docker.compose.service": "app"],
            remove: false,
            tty: false
        )
        #expect(exitCode == 0)

        let observed = try await adapter.observe(projectName: projectName)
        #expect(observed.count == 1, "the one-off container must not appear alongside the managed one")
        #expect(observed.first?.containerID == containerName)

        // Best-effort cleanup of the one-off container itself — it is not
        // named `containerName`, so the shared `cleanUp` helper cannot reach
        // it. Not asserted on: cleanup failing must not fail the test.
        let listing = try? ContainerCLI.run(["ls", "--all", "--format", "json"])
        if let stdout = listing?.stdout, let data = stdout.data(using: .utf8),
           let entries = try? JSONDecoder().decode([WireContainerEntry].self, from: data) {
            for entry in entries where entry.configuration.labels?[ContainerRuntimeAdapter.oneOffLabel] == "True" {
                _ = try? ContainerCLI.run(["delete", "--force", entry.configuration.id])
            }
        }
    }
}
