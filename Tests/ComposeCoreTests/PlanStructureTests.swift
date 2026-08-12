//
//  PlanStructureTests.swift
//  container-compose
//

import Testing
import Foundation
@testable import ComposeCore

@Suite("Dependency ordering")
struct OrderingTests {

    private func plan(_ document: String, requested: [String] = [], profiles: Set<String> = []) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "p", activeProfiles: profiles, requestedServices: requested)
        )
    }

    @Test("Independent services share one wave")
    func independentServicesShareAWave() throws {
        let result = try plan("""
            services:
              a: { image: alpine }
              b: { image: alpine }
              c: { image: alpine }
            """)

        // Nothing constrains these, so they start together rather than in
        // sequence — the difference between a 3x and a 1x startup.
        #expect(result.waves == [["a", "b", "c"]])
    }

    @Test("A chain yields one service per wave")
    func chainIsSequential() throws {
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

        #expect(result.waves == [["db"], ["api"], ["web"]])
    }

    @Test("A diamond puts independent middles together")
    func diamond() throws {
        let result = try plan("""
            services:
              db: { image: postgres }
              api:
                image: alpine
                depends_on: [db]
              worker:
                image: alpine
                depends_on: [db]
              web:
                image: nginx
                depends_on: [api, worker]
            """)

        #expect(result.waves == [["db"], ["api", "worker"], ["web"]])
    }

    @Test("Services are ordered so dependencies always precede dependents")
    func topologicalOrder() throws {
        let result = try plan("""
            services:
              web:
                image: nginx
                depends_on: [api]
              api:
                image: alpine
                depends_on: [db]
              db: { image: postgres }
            """)

        let order = result.services.map(\.name)
        for service in result.services {
            let index = try #require(order.firstIndex(of: service.name))
            for dependency in service.dependsOn {
                let dependencyIndex = try #require(order.firstIndex(of: dependency.service))
                #expect(dependencyIndex < index, "\(dependency.service) must precede \(service.name)")
            }
        }
    }

    @Test("A dependency cycle is reported rather than hanging")
    func cycleIsReported() throws {
        #expect(throws: PlanError.dependencyCycle(["a", "b"])) {
            _ = try plan("""
                services:
                  a:
                    image: alpine
                    depends_on: [b]
                  b:
                    image: alpine
                    depends_on: [a]
                """)
        }
    }

    @Test("The long depends_on form carries its condition")
    func dependsOnConditions() throws {
        let result = try plan("""
            services:
              db: { image: postgres }
              api:
                image: alpine
                depends_on:
                  db:
                    condition: service_healthy
            """)

        let api = try #require(result.service(named: "api"))
        #expect(api.dependsOn == [ServiceDependency(service: "db", condition: .healthy)])
    }
}

@Suite("Profiles and selection")
struct SelectionTests {

    private func plan(_ document: String, requested: [String] = [], profiles: Set<String> = []) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "p", activeProfiles: profiles, requestedServices: requested)
        )
    }

    @Test("Profiled services are excluded unless their profile is active")
    func profileGating() throws {
        let document = """
            services:
              web: { image: nginx }
              debug:
                image: alpine
                profiles: [debug]
            """

        #expect(try plan(document).services.map(\.name) == ["web"])
        #expect(try plan(document, profiles: ["debug"]).services.map(\.name).sorted() == ["debug", "web"])
    }

    @Test("Naming a service explicitly bypasses its profile gate")
    func explicitRequestBypassesProfile() throws {
        let result = try plan("""
            services:
              web: { image: nginx }
              debug:
                image: alpine
                profiles: [debug]
            """, requested: ["debug"])

        #expect(result.services.map(\.name) == ["debug"])
    }

    @Test("Dependencies are pulled in even when profile-gated")
    func dependenciesBypassProfiles() throws {
        // Starting `api` without `db` would fail, so the gate cannot apply to
        // something reached through depends_on.
        let result = try plan("""
            services:
              api:
                image: alpine
                depends_on: [db]
              db:
                image: postgres
                profiles: [storage]
            """, requested: ["api"])

        #expect(result.services.map(\.name).sorted() == ["api", "db"])
    }
}

@Suite("Inheritance via extends")
struct ExtendsTests {

    private func plan(_ document: String, files: [String: String] = [:]) throws -> Plan {
        try Planner(files: InMemoryProvider(files)).plan(
            document: document,
            options: PlanOptions(projectName: "p")
        )
    }

    @Test("Shorthand extends inherits from the same file")
    func shorthand() throws {
        let result = try plan("""
            services:
              base:
                image: alpine
                working_dir: /srv
              web:
                extends: base
            """)

        let web = try #require(result.service(named: "web"))
        #expect(web.image == "alpine")
    }

    @Test("Local values win over inherited ones")
    func localWins() throws {
        let result = try plan("""
            services:
              base:
                image: alpine
                environment:
                  MODE: production
                  KEEP: yes
              web:
                extends: base
                image: busybox
                environment:
                  MODE: dev
            """)

        let web = try #require(result.service(named: "web"))
        #expect(web.image == "busybox")
        #expect(web.environment["MODE"] == "dev")
        #expect(web.environment["KEEP"] != nil, "unrelated inherited keys must survive")
    }

    @Test("Multi-value options concatenate, base first")
    func concatenation() throws {
        let result = try plan("""
            services:
              base:
                image: alpine
                ports: ["8001:80"]
              web:
                extends: base
                ports: ["8002:81"]
            """)

        let web = try #require(result.service(named: "web"))
        #expect(web.ports == ["8001:80", "8002:81"])
    }

    @Test("Inheritance chains resolve transitively")
    func chained() throws {
        let result = try plan("""
            services:
              root:
                image: alpine
                working_dir: /srv
              middle:
                extends: root
              leaf:
                extends: middle
            """)

        let leaf = try #require(result.service(named: "leaf"))
        #expect(leaf.image == "alpine")
    }

    @Test("extends across files resolves relative to the referencing document")
    func acrossFiles() throws {
        let result = try plan("""
            services:
              web:
                extends:
                  file: common.yml
                  service: base
            """, files: [
                "common.yml": """
                    services:
                      base:
                        image: alpine
                        environment:
                          FROM_BASE: "1"
                    """
            ])

        let web = try #require(result.service(named: "web"))
        #expect(web.image == "alpine")
        #expect(web.environment["FROM_BASE"] == "1")
    }

    @Test("A cycle is reported rather than recursing forever")
    func cycle() throws {
        #expect(throws: (any Error).self) {
            _ = try plan("""
                services:
                  a: { extends: b }
                  b: { extends: a }
                """)
        }
    }

    @Test("Extending something that does not exist is an error")
    func missingTarget() throws {
        #expect(throws: (any Error).self) {
            _ = try plan("""
                services:
                  a:
                    image: alpine
                    extends: nope
                """)
        }
    }
}

@Suite("Runtime capabilities")
struct CapabilityTests {

    private func plan(_ document: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "p")
        )
    }

    @Test("Expressible keys become runtime flags")
    func supportedKeysBecomeFlags() throws {
        let result = try plan("""
            services:
              app:
                image: alpine
                cap_add: [NET_ADMIN]
                dns: 1.1.1.1
                init: true
                shm_size: 64M
            """)

        let app = try #require(result.service(named: "app"))
        let flags = app.runtimeOptions
        #expect(flags.contains(RuntimeOption(flag: "--cap-add", value: "NET_ADMIN")))
        #expect(flags.contains(RuntimeOption(flag: "--dns", value: "1.1.1.1")))
        #expect(flags.contains(RuntimeOption(flag: "--init")))
        #expect(flags.contains(RuntimeOption(flag: "--shm-size", value: "64M")))
    }

    @Test("Both ulimits spellings normalize to the same flag form")
    func ulimitsNormalization() throws {
        let shorthand = try plan("""
            services:
              app:
                image: alpine
                ulimits:
                  nproc: 512
            """)
        let shorthandApp = try #require(shorthand.service(named: "app"))
        #expect(shorthandApp.runtimeOptions.contains(RuntimeOption(flag: "--ulimit", value: "nproc=512")))

        let detailed = try plan("""
            services:
              app:
                image: alpine
                ulimits:
                  nofile:
                    soft: 1024
                    hard: 2048
            """)
        let detailedApp = try #require(detailed.service(named: "app"))
        #expect(detailedApp.runtimeOptions.contains(RuntimeOption(flag: "--ulimit", value: "nofile=1024:2048")))
    }

    @Test("Inexpressible keys are reported on the plan, before anything runs")
    func unsupportedKeysAreReported() throws {
        let result = try plan("""
            services:
              app:
                image: alpine
                restart: unless-stopped
                sysctls:
                  net.ipv4.ip_forward: 1
            """)

        let app = try #require(result.service(named: "app"))
        let keys = app.unsupported.map(\.key)
        #expect(keys.contains("restart"))
        #expect(keys.contains("sysctls"))
        // The reason must describe the runtime's limitation, so a consumer can
        // explain it rather than just flagging the key.
        let restart = try #require(app.unsupported.first { $0.key == "restart" })
        #expect(restart.support == .none)
        #expect(restart.reason.contains("restart-policy"))
    }

    @Test("Partially-supported keys say what does apply")
    func partialSupport() throws {
        let result = try plan("""
            services:
              app:
                image: alpine
                deploy:
                  replicas: 3
            """)

        let app = try #require(result.service(named: "app"))
        let deploy = try #require(app.unsupported.first { $0.key == "deploy" })
        #expect(deploy.support == .partial)
        #expect(deploy.detail?.contains("resources.limits") == true)
    }

    @Test("A project using only expressible keys reports nothing unsupported")
    func cleanProject() throws {
        let result = try plan("""
            services:
              app:
                image: alpine
                ports: ["80:80"]
                environment:
                  A: "1"
            """)

        let app = try #require(result.service(named: "app"))
        #expect(app.unsupported.isEmpty)
    }
}

@Suite("Config hashing for reconciliation")
struct ConfigHashTests {

    private func plan(_ document: String, variables: [String: String] = [:]) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "p", variables: variables)
        )
    }

    @Test("The same input yields the same hash")
    func stableAcrossRuns() throws {
        let document = """
            services:
              app:
                image: alpine
                environment:
                  A: "1"
            """
        let firstPlan = try plan(document)
        let secondPlan = try plan(document)
        let first = try #require(firstPlan.service(named: "app")).configHash
        let second = try #require(secondPlan.service(named: "app")).configHash

        // Must not use Hasher: it is seeded per process, so a hash stamped on a
        // container today would never match tomorrow's.
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("A changed value changes the hash")
    func detectsChange() throws {
        let beforePlan = try plan("""
            services:
              app:
                image: alpine
                environment:
                  A: "1"
            """)
        let afterPlan = try plan("""
            services:
              app:
                image: alpine
                environment:
                  A: "2"
            """)
        let before = try #require(beforePlan.service(named: "app")).configHash
        let after = try #require(afterPlan.service(named: "app")).configHash

        #expect(before != after)
    }

    @Test("A change only in an interpolated value still changes the hash")
    func detectsInterpolatedChange() throws {
        let document = """
            services:
              app:
                image: alpine:${TAG}
            """
        let firstPlan = try plan(document, variables: ["TAG": "3.19"])
        let secondPlan = try plan(document, variables: ["TAG": "3.20"])
        let first = try #require(firstPlan.service(named: "app")).configHash
        let second = try #require(secondPlan.service(named: "app")).configHash

        // The document text is identical; only the resolved value differs. A
        // hash over the raw file would miss this and leave a stale container.
        #expect(first != second)
    }

    @Test("Reformatting without semantic change keeps the hash")
    func ignoresFormatting() throws {
        let inlinePlan = try plan("""
            services:
              app: { image: alpine, environment: { A: "1" } }
            """)
        let expandedPlan = try plan("""
            services:
              app:
                image: alpine
                environment:
                  A: "1"
            """)
        let inline = try #require(inlinePlan.service(named: "app")).configHash
        let expanded = try #require(expandedPlan.service(named: "app")).configHash

        // Reconciliation must not recreate containers because someone
        // reformatted the YAML.
        #expect(inline == expanded)
    }
}
