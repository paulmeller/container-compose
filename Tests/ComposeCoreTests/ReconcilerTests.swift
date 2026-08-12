//
//  ReconcilerTests.swift
//  container-compose
//
//  The central claim of this project: "make reality match the file" instead
//  of "delete and recreate". Every test here is a pure data-in/data-out
//  assertion — no daemon, no containers, milliseconds.
//

import Testing
import Foundation
@testable import ComposeCore

@Suite("Reconciliation")
struct ReconcilerTests {

    private func plan(_ document: String, variables: [String: String] = [:]) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "p", variables: variables)
        )
    }

    private func hash(_ plan: Plan, _ service: String) throws -> String {
        try #require(plan.service(named: service)).configHash
    }

    @Test("A service with no observed container is created")
    func missingContainerIsCreated() throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)

        let actions = Reconciler.plan(desired: result, observed: [])

        #expect(actions == [[.create(service: try #require(result.service(named: "web")))]])
    }

    @Test("A running container with a matching hash needs nothing")
    func matchingRunningContainerIsUnchanged() throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let observed = ObservedContainer(
            service: "web", containerID: "abc", running: true, configHash: try hash(result, "web")
        )

        let actions = Reconciler.plan(desired: result, observed: [observed])

        // This is the case a delete-and-recreate implementation cannot
        // express: an already-correct, already-running container is left
        // alone rather than torn down and rebuilt.
        #expect(actions == [[.unchanged(service: try #require(result.service(named: "web")), containerID: "abc")]])
    }

    @Test("A stopped container with a matching hash is started, not recreated")
    func matchingStoppedContainerIsStarted() throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let observed = ObservedContainer(
            service: "web", containerID: "abc", running: false, configHash: try hash(result, "web")
        )

        let actions = Reconciler.plan(desired: result, observed: [observed])

        #expect(actions == [[.start(service: try #require(result.service(named: "web")), containerID: "abc")]])
    }

    @Test("A container whose hash no longer matches is recreated, with a reason")
    func mismatchedHashIsRecreated() throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let observed = ObservedContainer(service: "web", containerID: "abc", running: true, configHash: "stale-hash")

        let actions = Reconciler.plan(desired: result, observed: [observed])

        guard case .recreate(let service, let id, let reason) = actions[0][0] else {
            Issue.record("expected .recreate, got \(actions)")
            return
        }
        #expect(service.name == "web")
        #expect(id == "abc")
        #expect(!reason.isEmpty, "a recreate must say why, not just that it happened")
    }

    @Test("A container with no recorded hash is treated as changed, not trusted")
    func unknownProvenanceIsRecreated() throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        // No configHash at all — e.g. a container this tool did not create.
        let observed = ObservedContainer(service: "web", containerID: "abc", running: true, configHash: nil)

        let actions = Reconciler.plan(desired: result, observed: [observed])

        guard case .recreate = actions[0][0] else {
            Issue.record("expected .recreate for a container with unknown provenance, got \(actions)")
            return
        }
    }

    @Test("Actions are grouped by wave, matching the plan's own waves")
    func actionsRespectWaves() throws {
        let result = try plan("""
            services:
              db: { image: postgres }
              api:
                image: alpine
                depends_on: [db]
            """)

        let actions = Reconciler.plan(desired: result, observed: [])

        #expect(actions.count == 2)
        #expect(actions[0].map { $0.service.name } == ["db"])
        #expect(actions[1].map { $0.service.name } == ["api"])
    }

    @Test("Independent services reconcile within the same wave")
    func independentServicesShareAWave() throws {
        let result = try plan("""
            services:
              a: { image: alpine }
              b: { image: alpine }
            """)

        let actions = Reconciler.plan(desired: result, observed: [])

        #expect(actions.count == 1)
        #expect(Set(actions[0].map { $0.service.name }) == ["a", "b"])
    }

    @Test("A mixed project reconciles each service independently")
    func mixedReconciliation() throws {
        let result = try plan("""
            services:
              unchanged: { image: alpine }
              needs-start: { image: alpine }
              needs-recreate: { image: alpine }
              needs-create: { image: alpine }
            """)

        let observed = [
            ObservedContainer(service: "unchanged", containerID: "1", running: true, configHash: try hash(result, "unchanged")),
            ObservedContainer(service: "needs-start", containerID: "2", running: false, configHash: try hash(result, "needs-start")),
            ObservedContainer(service: "needs-recreate", containerID: "3", running: true, configHash: "old"),
            // needs-create: nothing observed.
        ]

        let actions = Reconciler.plan(desired: result, observed: observed).flatMap { $0 }
        let byName = Dictionary(uniqueKeysWithValues: actions.map { ($0.service.name, $0) })

        if case .unchanged = byName["unchanged"] {} else { Issue.record("expected unchanged") }
        if case .start = byName["needs-start"] {} else { Issue.record("expected start") }
        if case .recreate = byName["needs-recreate"] {} else { Issue.record("expected recreate") }
        if case .create = byName["needs-create"] {} else { Issue.record("expected create") }
    }

    @Test("Reconciling twice with unchanged state is idempotent")
    func idempotent() throws {
        // The property that makes clicking "up" repeatedly safe: reconciling
        // against the SAME observed state twice must yield the same answer.
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let observed = ObservedContainer(
            service: "web", containerID: "abc", running: true, configHash: try hash(result, "web")
        )

        let first = Reconciler.plan(desired: result, observed: [observed])
        let second = Reconciler.plan(desired: result, observed: [observed])

        #expect(first == second)
    }
}
