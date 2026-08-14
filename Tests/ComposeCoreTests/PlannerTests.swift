//
//  PlannerTests.swift
//  container-compose
//
//  Every test here runs without a container runtime, a daemon, or the
//  filesystem. That is the point of the Core layer: the parts that are hard to
//  get right — interpolation, inheritance, ordering, capability reporting —
//  are pure functions, so they can be tested exhaustively and in milliseconds.
//

import Testing
import Foundation
@testable import ComposeCore

@Suite("Planning")
struct PlannerTests {

    private func plan(
        _ document: String,
        files: [String: String] = [:],
        projectName: String = "proj",
        variables: [String: String] = [:],
        profiles: Set<String> = [],
        requested: [String] = []
    ) throws -> Plan {
        try Planner(files: InMemoryProvider(files)).plan(
            document: document,
            options: PlanOptions(
                projectName: projectName,
                variables: variables,
                activeProfiles: profiles,
                requestedServices: requested
            )
        )
    }

    @Test("A minimal document plans one service")
    func minimalDocument() throws {
        let result = try plan("""
            services:
              web:
                image: nginx:alpine
            """)

        #expect(result.services.count == 1)
        #expect(result.service(named: "web")?.image == "nginx:alpine")
        #expect(result.waves == [["web"]])
    }

    @Test("Compose labels are stamped and cannot be overridden")
    func composeLabelsAreStamped() throws {
        let result = try plan("""
            services:
              web:
                image: nginx
                labels:
                  com.docker.compose.project: hijacked
                  mine: kept
            """)

        let web = try #require(result.service(named: "web"))
        // These are how every other layer finds the project's containers, so a
        // user value must not be able to break that.
        #expect(web.labels["com.docker.compose.project"] == "proj")
        #expect(web.labels["com.docker.compose.service"] == "web")
        #expect(web.labels["mine"] == "kept")
    }

    @Test("A service with neither image nor build is rejected")
    func serviceNeedsImageOrBuild() throws {
        #expect(throws: PlanError.serviceMissingImageAndBuild("web")) {
            _ = try plan("""
                services:
                  web:
                    command: ["true"]
                """)
        }
    }

    @Test("An unknown requested service fails immediately")
    func unknownRequestedService() throws {
        #expect(throws: PlanError.noSuchService("nope")) {
            _ = try plan("""
                services:
                  web:
                    image: nginx
                """, requested: ["nope"])
        }
    }
}

@Suite("Interpolation")
struct InterpolationTests {

    private func resolve(_ value: String, _ variables: [String: String] = [:]) throws -> String {
        try Interpolation.resolve(value, variables: variables)
    }

    @Test("Plain and braced references resolve")
    func basicForms() throws {
        #expect(try resolve("${HOST}", ["HOST": "example.com"]) == "example.com")
        #expect(try resolve("$HOST", ["HOST": "example.com"]) == "example.com")
        #expect(try resolve("https://${HOST}/v1", ["HOST": "api.dev"]) == "https://api.dev/v1")
    }

    @Test("Several references in one value all resolve")
    func multipleReferences() throws {
        #expect(try resolve("${A}:${B}", ["A": "1", "B": "2"]) == "1:2")
    }

    @Test("Defaults apply only when appropriate for the operator")
    func defaults() throws {
        // `:-` treats empty as unset; `-` treats only missing as unset.
        #expect(try resolve("${X:-fallback}", [:]) == "fallback")
        #expect(try resolve("${X:-fallback}", ["X": ""]) == "fallback")
        #expect(try resolve("${X-fallback}", ["X": ""]) == "")
        #expect(try resolve("${X:-fallback}", ["X": "set"]) == "set")
    }

    @Test("Alternate-value form substitutes only when set")
    func alternateValue() throws {
        #expect(try resolve("${X:+yes}", ["X": "anything"]) == "yes")
        #expect(try resolve("${X:+yes}", [:]) == "")
    }

    @Test("Required form throws when unset")
    func requiredVariable() throws {
        #expect(throws: Interpolation.Failure.required(variable: "TOKEN", message: "must be set")) {
            _ = try resolve("${TOKEN:?must be set}", [:])
        }
        #expect(try resolve("${TOKEN:?must be set}", ["TOKEN": "abc"]) == "abc")
    }

    @Test("$$ escapes a literal dollar sign")
    func escaping() throws {
        // Without this, a shell command containing `$$` (a PID) would be
        // mangled into an empty variable expansion.
        #expect(try resolve("cost is $$5", [:]) == "cost is $5")
        #expect(try resolve("$${NOT_A_VAR}", ["NOT_A_VAR": "x"]) == "${NOT_A_VAR}")
    }

    @Test("Defaults may themselves contain references")
    func nestedDefault() throws {
        #expect(try resolve("${A:-${B}}", ["B": "inner"]) == "inner")
    }

    @Test("An unset variable with no default becomes empty")
    func unsetIsEmpty() throws {
        #expect(try resolve("[${MISSING}]", [:]) == "[]")
    }

    @Test("Text with no references is returned unchanged")
    func passthrough() throws {
        #expect(try resolve("plain text", ["A": "1"]) == "plain text")
    }
}

@Suite("Environment resolution")
struct EnvironmentTests {

    @Test("Service environment interpolates against supplied variables")
    func interpolatesFromVariables() throws {
        let result = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  api:
                    image: alpine
                    environment:
                      URL: postgres://${DB_HOST}/app
                """,
            options: PlanOptions(projectName: "p", variables: ["DB_HOST": "db.internal"])
        )

        #expect(result.service(named: "api")?.environment["URL"] == "postgres://db.internal/app")
    }

    @Test("env_file contributes variables, and inline values win over them")
    func envFilePrecedence() throws {
        let result = try Planner(files: InMemoryProvider([
            "api.env": """
                MODE=from-file
                ONLY_IN_FILE=yes
                """
        ])).plan(
            document: """
                services:
                  api:
                    image: alpine
                    env_file: [api.env]
                    environment:
                      MODE: from-service
                """,
            options: PlanOptions(projectName: "p")
        )

        let api = try #require(result.service(named: "api"))
        #expect(api.environment["MODE"] == "from-service")
        #expect(api.environment["ONLY_IN_FILE"] == "yes")
    }

    @Test("env_file values are visible to interpolation in the same service")
    func envFileFeedsInterpolation() throws {
        let result = try Planner(files: InMemoryProvider(["db.env": "DB_HOST=box"])).plan(
            document: """
                services:
                  api:
                    image: alpine
                    env_file: [db.env]
                    environment:
                      URL: http://${DB_HOST}
                """,
            options: PlanOptions(projectName: "p")
        )

        #expect(result.service(named: "api")?.environment["URL"] == "http://box")
    }

    @Test("The KEY=value list form is accepted")
    func listForm() throws {
        let result = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  api:
                    image: alpine
                    environment:
                      - PLAIN=1
                      - EMPTY=
                """,
            options: PlanOptions(projectName: "p")
        )

        let api = try #require(result.service(named: "api"))
        #expect(api.environment["PLAIN"] == "1")
        #expect(api.environment["EMPTY"] == "")
    }

    @Test("A bare key with no '=' inherits its value, rather than becoming empty")
    func bareKeyInheritsFromVariables() throws {
        // Compose spec: `- FOO` with no value takes FOO from the environment
        // the file is resolved against. Defaulting it to "" instead silently
        // blanks a variable the user expected to be passed through — and it is
        // the form nearly every Coolify template uses to declare its generated
        // values, so those all arrived empty.
        let result = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  api:
                    image: alpine
                    environment:
                      - INHERITED
                      - ABSENT
                """,
            options: PlanOptions(projectName: "p", variables: ["INHERITED": "from-the-environment"])
        )

        let api = try #require(result.service(named: "api"))
        #expect(api.environment["INHERITED"] == "from-the-environment")
        // Not present anywhere: still declared, still empty. Dropping the key
        // entirely would be a different behaviour, and a service that checks
        // "is this set" would see the opposite answer.
        #expect(api.environment["ABSENT"] == "")
    }

    @Test("Quotes around env-file values are delimiters, not content")
    func envFileQuoteStripping() throws {
        let parsed = Planner.parseEnvFile("""
            A="quoted"
            B='single'
            C=bare
            # comment
            """)

        #expect(parsed["A"] == "quoted")
        #expect(parsed["B"] == "single")
        #expect(parsed["C"] == "bare")
        #expect(parsed.count == 3)
    }
}

@Suite("Build context resolution")
struct BuildContextResolutionTests {

    private func plan(_ document: String, directory: String) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "proj", directory: directory)
        )
    }

    // Regression: `container build <context>` is shelled out with no
    // explicit working directory, so a relative context must be resolved
    // against the compose file's own directory here — otherwise it silently
    // resolves against wherever the CLI process happens to be running from,
    // which is not necessarily where the compose file lives.

    @Test("A shorthand string build: value resolves to an absolute path")
    func shorthandContextIsAbsolute() throws {
        let result = try plan("""
            services:
              app:
                build: ./app
            """, directory: "/projects/myapp")
        let build = try #require(result.service(named: "app")?.build)
        #expect(build.context == "/projects/myapp/app")
    }

    @Test("A mapping form's context: resolves to an absolute path")
    func mappingContextIsAbsolute() throws {
        let result = try plan("""
            services:
              app:
                build:
                  context: .
            """, directory: "/projects/myapp")
        let build = try #require(result.service(named: "app")?.build)
        #expect(build.context == "/projects/myapp")
    }

    @Test("An already-absolute context is left untouched")
    func alreadyAbsoluteContextUnchanged() throws {
        let result = try plan("""
            services:
              app:
                build:
                  context: /elsewhere/build-root
            """, directory: "/projects/myapp")
        let build = try #require(result.service(named: "app")?.build)
        #expect(build.context == "/elsewhere/build-root")
    }

    @Test("A relative dockerfile: resolves against the build context, not the compose file's directory")
    func relativeDockerfileResolvesAgainstContext() throws {
        let result = try plan("""
            services:
              app:
                build:
                  context: ./app
                  dockerfile: docker/Dockerfile.prod
            """, directory: "/projects/myapp")
        let build = try #require(result.service(named: "app")?.build)
        #expect(build.dockerfile == "/projects/myapp/app/docker/Dockerfile.prod")
    }

    @Test("An already-absolute dockerfile: is left untouched")
    func alreadyAbsoluteDockerfileUnchanged() throws {
        let result = try plan("""
            services:
              app:
                build:
                  context: ./app
                  dockerfile: /etc/dockerfiles/Dockerfile
            """, directory: "/projects/myapp")
        let build = try #require(result.service(named: "app")?.build)
        #expect(build.dockerfile == "/etc/dockerfiles/Dockerfile")
    }
}
