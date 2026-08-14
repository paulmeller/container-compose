//
//  EngineSeedingTests.swift
//  container-compose
//
//  Three behaviours learned from running real self-hosted apps rather than
//  fixtures: a fresh volume must carry the image's content and ownership, a
//  service must not be failed for its own slow healthcheck, and the image
//  check must say whether it actually fetched anything.
//

import Testing
import Foundation
import ComposeCore
import ComposeTestSupport
@testable import ComposeEngine

@Suite("Volume seeding and health gating")
struct EngineSeedingTests {

    private func plan(_ document: String, projectName: String = "proj") throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: projectName)
        )
    }

    @Test("A newly created volume is seeded from the image that mounts it")
    func newVolumeIsSeeded() async throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              app:
                image: n8nio/n8n
                volumes:
                  - data:/home/node/.n8n
            """)
        let adapter = FakeRuntimeAdapter()
        _ = await Engine(adapter: adapter).up(result)

        // Without this the volume mounts empty and root-owned, and an image
        // running as a non-root user cannot write its own data directory.
        let seeded = await adapter.seededVolumes
        #expect(seeded.count == 1)
        #expect(seeded.first?.volume == "proj_data")
        #expect(seeded.first?.image == "n8nio/n8n")
        #expect(seeded.first?.path == "/home/node/.n8n")
    }

    @Test("An existing volume is never seeded, because that would overwrite data")
    func existingVolumeIsNotSeeded() async throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              app:
                image: nginx
                volumes:
                  - data:/var/lib/data
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.seedVolume("proj_data")  // already there from an earlier run
        _ = await Engine(adapter: adapter).up(result)

        let seeded = await adapter.seededVolumes
        #expect(seeded.isEmpty, "seeding an existing volume would destroy whatever it holds")
    }

    @Test("A bind mount is never seeded — the host already owns that directory")
    func bindMountIsNotSeeded() async throws {
        let result = try plan("""
            services:
              app:
                image: nginx
                volumes:
                  - ./site:/usr/share/nginx/html
                  - /etc/localtime:/etc/localtime:ro
            """)
        let adapter = FakeRuntimeAdapter()
        _ = await Engine(adapter: adapter).up(result)

        let seeded = await adapter.seededVolumes
        #expect(seeded.isEmpty)
    }

    @Test("One volume mounted by two services is seeded once")
    func sharedVolumeIsSeededOnce() async throws {
        let result = try plan("""
            volumes:
              shared: {}
            services:
              a:
                image: alpine
                volumes:
                  - shared:/data
              b:
                image: busybox
                volumes:
                  - shared:/data
            """)
        let adapter = FakeRuntimeAdapter()
        _ = await Engine(adapter: adapter).up(result)

        // Both services are in one wave and run concurrently; the pending set
        // is actor-isolated so only the first to arrive seeds.
        let seeded = await adapter.seededVolumes
        #expect(seeded.count == 1, "a shared volume must be seeded exactly once")
    }

    @Test("An image with no shell cannot be seeded, and that is not a failure")
    func seedingWithoutAShellIsNotFatal() async throws {
        let result = try plan("""
            volumes:
              data: {}
            services:
              app:
                image: distroless
                volumes:
                  - data:/data
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.imageHasNoShell("distroless")
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, _, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        // The container still starts; plenty of images do not care.
        #expect(success)
        #expect(!events.contains { if case .volumeSeeded = $0 { return true } else { return false } })
    }

    @Test("A service is not failed for its own healthcheck when nothing depends on it")
    func ownHealthcheckDoesNotGate() async throws {
        let result = try plan("""
            services:
              app:
                image: n8nio/n8n
                healthcheck:
                  test: ["CMD", "false"]
                  retries: 1
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.failHealthcheck(forService: "app")
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, let ready, _, _) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        // n8n was serving traffic while `up` reported FAILED, purely because
        // its first-run migrations outlasted its own retry budget.
        #expect(success)
        #expect(ready == ["app"])
    }

    @Test("A service IS gated when a dependent asks for service_healthy")
    func dependentRequiringHealthGates() async throws {
        let result = try plan("""
            services:
              db:
                image: postgres
                healthcheck:
                  test: ["CMD", "pg_isready"]
                  retries: 1
              api:
                image: alpine
                depends_on:
                  db:
                    condition: service_healthy
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.failHealthcheck(forService: "db")
        let events = await Engine(adapter: adapter).up(result)

        guard case .done(let success, _, let failed, let skipped) = events.last else {
            Issue.record("expected a terminal .done event")
            return
        }
        // Here health genuinely is a precondition: starting `api` against a
        // database that is not accepting connections is the failure the
        // dependency exists to prevent.
        #expect(!success)
        #expect(failed == ["db"])
        #expect(skipped == ["api"])
    }

    @Test("An image already present is reported as present, not pulled")
    func presentImageIsNotReportedAsPulled() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let adapter = FakeRuntimeAdapter()
        await adapter.seedImage("nginx")
        let events = await Engine(adapter: adapter).up(result)

        let actions = events.compactMap { event -> ImageAction? in
            guard case .imageReady(_, _, let action) = event else { return nil }
            return action
        }
        // Reporting a no-op as a pull is what let a bug that re-fetched every
        // image on every run pass for a slow network.
        #expect(actions == [.present])
    }

    @Test("An image that was missing is reported as pulled")
    func missingImageIsReportedAsPulled() async throws {
        let result = try plan("""
            services:
              web: { image: nginx }
            """)
        let adapter = FakeRuntimeAdapter()
        let events = await Engine(adapter: adapter).up(result)

        let actions = events.compactMap { event -> ImageAction? in
            guard case .imageReady(_, _, let action) = event else { return nil }
            return action
        }
        #expect(actions == [.pulled])
    }
}
