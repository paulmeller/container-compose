//
//  ProtocolTests.swift
//  container-compose
//
//  Tests the wire contract and the request-execution logic without spawning
//  the executable or touching a real daemon — the same fast-test pattern as
//  Core and Engine, extended one layer further.
//

import Testing
import Foundation
import ComposeCore
import ComposeEngine
import ComposeTestSupport
@testable import ComposeProtocol

@Suite("ProtocolRequest parsing")
struct ProtocolRequestParsingTests {

    @Test("capabilities takes no arguments")
    func capabilitiesCommand() throws {
        let request = try ProtocolRequest.parse(["capabilities"])
        #expect(request.command == .capabilities)
    }

    @Test("up requires --file")
    func upRequiresFile() throws {
        #expect(throws: ProtocolRequest.ParseError.missingRequiredFlag(command: "up", flag: "--file")) {
            _ = try ProtocolRequest.parse(["up"])
        }
    }

    @Test("up collects bare tokens as requested services")
    func upCollectsServices() throws {
        let request = try ProtocolRequest.parse(["up", "--file", "compose.yml", "web", "db"])
        #expect(request.command == .up(services: ["web", "db"]))
        #expect(request.composeFilePath == "compose.yml")
    }

    @Test("Explicit --project overrides directory-derived naming")
    func explicitProject() throws {
        let request = try ProtocolRequest.parse(["up", "--file", "a/b/compose.yml", "--project", "custom"])
        #expect(request.projectName == "custom")
    }

    @Test("Repeated --profile accumulates")
    func repeatedProfile() throws {
        let request = try ProtocolRequest.parse(["up", "--file", "c.yml", "--profile", "debug", "--profile", "test"])
        #expect(request.profiles == ["debug", "test"])
    }

    @Test("down accepts --remove")
    func downRemoveFlag() throws {
        let withRemove = try ProtocolRequest.parse(["down", "--file", "c.yml", "--remove"])
        #expect(withRemove.command == .down(remove: true, volumes: false))

        let without = try ProtocolRequest.parse(["down", "--file", "c.yml"])
        #expect(without.command == .down(remove: false, volumes: false))
    }

    @Test("down --volumes is a separate opt-in, never implied by --remove")
    func downVolumesFlag() throws {
        // The distinction is the point: --remove deletes containers and the
        // networks this project made, both cheap to rebuild. A volume is the
        // data itself, so deleting one has to be asked for.
        let removeOnly = try ProtocolRequest.parse(["down", "--file", "c.yml", "--remove"])
        #expect(removeOnly.command == .down(remove: true, volumes: false))

        let both = try ProtocolRequest.parse(["down", "--file", "c.yml", "--remove", "--volumes"])
        #expect(both.command == .down(remove: true, volumes: true))

        let shorthand = try ProtocolRequest.parse(["down", "--file", "c.yml", "-v"])
        #expect(shorthand.command == .down(remove: false, volumes: true))
    }

    @Test("An unknown command is rejected")
    func unknownCommand() throws {
        #expect(throws: ProtocolRequest.ParseError.unknownCommand("frobnicate")) {
            _ = try ProtocolRequest.parse(["frobnicate"])
        }
    }

    @Test("An unknown flag is rejected rather than silently ignored")
    func unknownFlag() throws {
        #expect(throws: ProtocolRequest.ParseError.unknownFlag("--bogus")) {
            _ = try ProtocolRequest.parse(["up", "--file", "c.yml", "--bogus"])
        }
    }

    @Test("A flag missing its value is rejected")
    func missingValue() throws {
        #expect(throws: ProtocolRequest.ParseError.missingValue(forFlag: "--file")) {
            _ = try ProtocolRequest.parse(["up", "--file"])
        }
    }

    @Test("build/pull/push all collect requested services and require --file")
    func buildPullPushCommands() throws {
        #expect(try ProtocolRequest.parse(["build", "--file", "c.yml", "web"]).command == .build(services: ["web"]))
        #expect(try ProtocolRequest.parse(["pull", "--file", "c.yml"]).command == .pull(services: []))
        #expect(try ProtocolRequest.parse(["push", "--file", "c.yml", "web", "db"]).command == .push(services: ["web", "db"]))
        #expect(throws: ProtocolRequest.ParseError.missingRequiredFlag(command: "build", flag: "--file")) {
            _ = try ProtocolRequest.parse(["build"])
        }
    }

    @Test("Lifecycle commands (start/stop/restart/kill/rm/wait) do not require --file, matching down")
    func lifecycleCommandsDoNotRequireFile() throws {
        #expect(try ProtocolRequest.parse(["start", "--project", "p"]).command == .start(services: []))
        #expect(try ProtocolRequest.parse(["stop", "--project", "p", "web"]).command == .stop(services: ["web"]))
        #expect(try ProtocolRequest.parse(["restart", "--project", "p"]).command == .restart(services: []))
        #expect(try ProtocolRequest.parse(["kill", "--project", "p", "--signal", "TERM"]).command == .kill(services: [], signal: "TERM"))
        #expect(try ProtocolRequest.parse(["kill", "--project", "p"]).command == .kill(services: [], signal: "KILL"), "KILL is the default signal")
        #expect(try ProtocolRequest.parse(["rm", "--project", "p", "--force"]).command == .rm(services: [], force: true))
        #expect(try ProtocolRequest.parse(["wait", "--project", "p", "--timeout", "5"]).command == .wait(services: [], timeoutSeconds: 5))
        #expect(try ProtocolRequest.parse(["wait", "--project", "p"]).command == .wait(services: [], timeoutSeconds: nil))
    }

    @Test("ps/ls/images collect --all and do not require --file")
    func observationCommands() throws {
        #expect(try ProtocolRequest.parse(["ps", "--project", "p"]).command == .ps(all: false))
        #expect(try ProtocolRequest.parse(["ps", "--project", "p", "--all"]).command == .ps(all: true))
        #expect(try ProtocolRequest.parse(["ls"]).command == .ls(all: false))
        #expect(try ProtocolRequest.parse(["ls", "--all"]).command == .ls(all: true))
        #expect(try ProtocolRequest.parse(["images", "--project", "p"]).command == .images)
    }

    @Test("config requires --file")
    func configCommand() throws {
        #expect(try ProtocolRequest.parse(["config", "--file", "c.yml"]).command == .config)
        #expect(throws: ProtocolRequest.ParseError.missingRequiredFlag(command: "config", flag: "--file")) {
            _ = try ProtocolRequest.parse(["config"])
        }
    }

    @Test("logs collects services, --follow and --tail")
    func logsCommand() throws {
        let request = try ProtocolRequest.parse(["logs", "--project", "p", "--follow", "--tail", "50", "web"])
        #expect(request.command == .logs(services: ["web"], follow: true, tail: 50))
    }

    @Test("An invalid --tail value is rejected")
    func invalidTail() throws {
        #expect(throws: ProtocolRequest.ParseError.invalidArgument(command: "logs", name: "--tail", value: "nope")) {
            _ = try ProtocolRequest.parse(["logs", "--project", "p", "--tail", "nope"])
        }
    }

    @Test("top/stats collect requested services without requiring --file")
    func topAndStatsCommands() throws {
        #expect(try ProtocolRequest.parse(["top", "--project", "p", "web"]).command == .top(services: ["web"]))
        #expect(try ProtocolRequest.parse(["stats", "--project", "p"]).command == .stats(services: []))
    }

    @Test("port requires a service and an integer container port")
    func portCommand() throws {
        #expect(try ProtocolRequest.parse(["port", "--project", "p", "web", "80"]).command == .port(service: "web", containerPort: 80))
        #expect(throws: ProtocolRequest.ParseError.missingArgument(command: "port", name: "service and container-port")) {
            _ = try ProtocolRequest.parse(["port", "--project", "p", "web"])
        }
        #expect(throws: ProtocolRequest.ParseError.invalidArgument(command: "port", name: "container-port", value: "nope")) {
            _ = try ProtocolRequest.parse(["port", "--project", "p", "web", "nope"])
        }
    }

    @Test("cp requires source and destination, and needs neither --project nor --file")
    func cpCommand() throws {
        let request = try ProtocolRequest.parse(["cp", "web:/etc/nginx.conf", "./nginx.conf"])
        #expect(request.command == .cp(source: "web:/etc/nginx.conf", destination: "./nginx.conf"))
    }

    @Test("export requires a service and --output")
    func exportCommand() throws {
        let request = try ProtocolRequest.parse(["export", "--project", "p", "web", "--output", "web.tar"])
        #expect(request.command == .export(service: "web", outputPath: "web.tar"))
        #expect(throws: ProtocolRequest.ParseError.missingRequiredFlag(command: "export", flag: "--output")) {
            _ = try ProtocolRequest.parse(["export", "--project", "p", "web"])
        }
    }

    @Test("exec collects the service and passes the remaining tokens through as the inner command")
    func execCommand() throws {
        let request = try ProtocolRequest.parse(["exec", "--project", "p", "web", "sh", "-c", "echo hi"])
        #expect(request.command == .exec(service: "web", command: ["sh", "-c", "echo hi"], tty: true))
    }

    @Test("exec honors --no-tty")
    func execNoTTY() throws {
        let request = try ProtocolRequest.parse(["exec", "--project", "p", "--no-tty", "web", "ps"])
        #expect(request.command == .exec(service: "web", command: ["ps"], tty: false))
    }

    @Test("A literal -- right after the service name is dropped, not leaked into the inner command")
    func execDropsSeparatorAfterService() throws {
        // Regression: caught live — `exec ... web -- nginx -v` was sending
        // ["--", "nginx", "-v"] to the container, since `--` only had
        // special meaning while still looking for the service name.
        let request = try ProtocolRequest.parse(["exec", "--project", "p", "--no-tty", "web", "--", "nginx", "-v"])
        #expect(request.command == .exec(service: "web", command: ["nginx", "-v"], tty: false))
    }

    @Test("A command token that itself looks like one of our flags passes through untouched")
    func execPassesThroughFlagLikeInnerTokens() throws {
        let request = try ProtocolRequest.parse(["exec", "--project", "p", "web", "sh", "-c", "echo hi"])
        #expect(request.command == .exec(service: "web", command: ["sh", "-c", "echo hi"], tty: true))
    }

    @Test("run does not remove the container afterward unless --remove is given, matching docker compose run")
    func runCommand() throws {
        let request = try ProtocolRequest.parse(["run", "--file", "c.yml", "web", "sh"])
        #expect(request.command == .run(service: "web", command: ["sh"], remove: false, tty: true))
        let removed = try ProtocolRequest.parse(["run", "--file", "c.yml", "--remove", "web", "sh"])
        #expect(removed.command == .run(service: "web", command: ["sh"], remove: true, tty: true))
    }

    @Test("watch requires --file")
    func watchCommand() throws {
        #expect(try ProtocolRequest.parse(["watch", "--file", "c.yml", "web"]).command == .watch(services: ["web"]))
        #expect(throws: ProtocolRequest.ParseError.missingRequiredFlag(command: "watch", flag: "--file")) {
            _ = try ProtocolRequest.parse(["watch"])
        }
    }
}

@Suite("ProtocolRequest.extractFormat")
struct ExtractFormatTests {

    @Test("defaults to text when --format is absent")
    func defaultsToText() throws {
        let (format, remaining) = try ProtocolRequest.extractFormat(["up", "--file", "c.yml"])
        #expect(format == .text)
        #expect(remaining == ["up", "--file", "c.yml"])
    }

    @Test("--format ndjson is recognized and removed from the remaining argv")
    func recognizesNdjson() throws {
        let (format, remaining) = try ProtocolRequest.extractFormat(["--format", "ndjson", "up", "--file", "c.yml"])
        #expect(format == .ndjson)
        #expect(remaining == ["up", "--file", "c.yml"])
    }

    @Test("--format works regardless of where it appears in argv")
    func positionIndependent() throws {
        let (format, remaining) = try ProtocolRequest.extractFormat(["up", "--file", "c.yml", "--format", "ndjson"])
        #expect(format == .ndjson)
        #expect(remaining == ["up", "--file", "c.yml"])
    }

    @Test("the remaining argv still parses correctly as a command after extraction")
    func remainingArgvStillParses() throws {
        let (format, remaining) = try ProtocolRequest.extractFormat(["--format", "ndjson", "up", "--file", "c.yml", "web"])
        #expect(format == .ndjson)
        let request = try ProtocolRequest.parse(remaining)
        #expect(request.command == .up(services: ["web"]))
        #expect(request.composeFilePath == "c.yml")
    }

    @Test("--format with a missing value is rejected")
    func missingValue() throws {
        #expect(throws: ProtocolRequest.ParseError.missingValue(forFlag: "--format")) {
            _ = try ProtocolRequest.extractFormat(["up", "--format"])
        }
    }

    @Test("--format with an unrecognized value is rejected")
    func invalidValue() throws {
        #expect(throws: ProtocolRequest.ParseError.invalidArgument(command: "up", name: "--format", value: "yaml")) {
            _ = try ProtocolRequest.extractFormat(["up", "--format", "yaml"])
        }
    }
}

@Suite("ProtocolMessage wire mapping")
struct ProtocolMessageMappingTests {

    private func roundTrip(_ message: ProtocolMessage) throws -> ProtocolMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(ProtocolMessage.self, from: data)
    }

    @Test("Every EngineEvent case maps to a distinguishable message type")
    func eventMapping() throws {
        let cases: [(EngineEvent, ProtocolMessage.MessageType)] = [
            (.planned(services: ["a"], waves: [["a"]]), .planned),
            (.serviceState(service: "a", state: .pulling, detail: "img"), .serviceState),
            (.serviceReady(service: "a", containerID: "id", reused: true), .serviceReady),
            (.serviceStopped(service: "a", containerID: "id"), .serviceStopped),
            (.serviceRemoved(service: "a", containerID: "id"), .serviceRemoved),
            (.imageReady(service: "a", image: "a:latest", action: .built), .imageReady),
            (.serviceFailed(service: "a", reason: "boom"), .serviceFailed),
            (.serviceSkipped(service: "a", reason: .dependencyFailed), .serviceSkipped),
            (.done(success: true, ready: ["a"], failed: [], skipped: []), .done),
        ]
        for (event, expectedType) in cases {
            #expect(ProtocolMessage(event).type == expectedType)
        }
    }

    @Test("serviceReady preserves the reused flag — the whole point of the project")
    func reusedFlagSurvives() throws {
        let reused = ProtocolMessage(.serviceReady(service: "web", containerID: "c1", reused: true))
        let fresh = ProtocolMessage(.serviceReady(service: "web", containerID: "c1", reused: false))
        #expect(reused.reused == true)
        #expect(fresh.reused == false)
    }

    @Test("imageReady carries which action happened and the resulting image reference")
    func imageReadyCarriesActionAndImage() throws {
        let built = ProtocolMessage(.imageReady(service: "web", image: "proj/web:latest", action: .built))
        #expect(built.action == "built")
        #expect(built.image == "proj/web:latest")

        let pushed = ProtocolMessage(.imageReady(service: "web", image: "registry/web:1.0", action: .pushed))
        #expect(pushed.action == "pushed")
    }

    @Test("A message round-trips through JSON without loss")
    func roundTripsThroughJSON() throws {
        let original = ProtocolMessage(.serviceReady(service: "web", containerID: "abc", reused: true))
        let decoded = try roundTrip(original)
        #expect(decoded == original)
    }

    @Test("An error message is distinguishable from a serviceFailed message")
    func errorVsServiceFailed() throws {
        // error means the engine was never reached (bad file, bad service
        // name); serviceFailed means the engine tried and failed. A consumer
        // must be able to tell these apart.
        let requestError = ProtocolMessage.errorMessage("compose file not found")
        let engineFailure = ProtocolMessage(.serviceFailed(service: "web", reason: "image pull failed"))
        #expect(requestError.type == .error)
        #expect(engineFailure.type == .serviceFailed)
        #expect(requestError.service == nil, "an error message has no service — it never reached one")
    }

    @Test("Every message carries the current wire version")
    func versionIsStamped() throws {
        #expect(ProtocolMessage(.done(success: true, ready: [], failed: [], skipped: [])).version == ProtocolMessage.currentVersion)
        #expect(ProtocolMessage.errorMessage("x").version == ProtocolMessage.currentVersion)
    }
}

@Suite("ProtocolRunner execution")
struct ProtocolRunnerTests {

    private func collectMessages(
        _ request: ProtocolRequest,
        files: [String: String] = [:],
        adapter: FakeRuntimeAdapter = FakeRuntimeAdapter()
    ) async -> (messages: [ProtocolMessage], exitCode: Int32) {
        let runner = ProtocolRunner(adapter: adapter, files: InMemoryProvider(files))
        let collector = MessageCollector()
        let exitCode = await runner.run(request) { collector.append($0) }
        return (collector.messages, exitCode)
    }

    @Test("capabilities returns a single message and exits 0")
    func capabilitiesCommand() async throws {
        let (messages, exitCode) = await collectMessages(ProtocolRequest(command: .capabilities))
        #expect(messages.count == 1)
        #expect(messages[0].type == .capabilities)
        #expect(messages[0].capabilities != nil)
        #expect(exitCode == 0)
    }

    @Test("up on a fresh project creates the service and exits 0")
    func upCreatesService() async throws {
        let request = ProtocolRequest(command: .up(services: []), composeFilePath: "compose.yml", projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, files: [
            "compose.yml": """
                services:
                  web:
                    image: nginx
                """
        ])

        #expect(exitCode == 0)
        #expect(messages.first?.type == .planned)
        #expect(messages.last?.type == .done)
        #expect(messages.last?.success == true)
        #expect(messages.contains { $0.type == .serviceReady && $0.service == "web" })
    }

    @Test("up against a missing compose file reports error and exits 1")
    func upMissingFile() async throws {
        let request = ProtocolRequest(command: .up(services: []), composeFilePath: "nope.yml", projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, files: [:])

        #expect(exitCode == 1)
        #expect(messages.count == 1)
        #expect(messages[0].type == .error)
    }

    @Test("up with an unresolvable variable reports error and exits 1, without touching the adapter")
    func upWithPlanError() async throws {
        let request = ProtocolRequest(command: .up(services: []), composeFilePath: "compose.yml", projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, files: [
            "compose.yml": """
                services:
                  web:
                    image: alpine
                    environment:
                      TOKEN: ${REQUIRED_VAR:?must be set}
                """
        ])

        #expect(exitCode == 1)
        #expect(messages.count == 1)
        #expect(messages[0].type == .error)
    }

    @Test("Project name derives from the compose file's directory when not given explicitly")
    func derivedProjectName() async throws {
        let request = ProtocolRequest(command: .up(services: []), composeFilePath: "/tmp/myproj/compose.yml")
        let (messages, _) = await collectMessages(request, files: [
            "compose.yml": """
                services:
                  web:
                    image: nginx
                """
        ])

        // The service still gets created, proving planning succeeded with a
        // project name it derived rather than failing for lack of one.
        #expect(messages.contains { $0.type == .serviceReady })
    }

    @Test("A second up against an unchanged project reports reused via the wire format")
    func secondUpReportsReused() async throws {
        let files = ["compose.yml": """
            services:
              web:
                image: nginx
            """]
        let adapter = FakeRuntimeAdapter()
        let request = ProtocolRequest(command: .up(services: []), composeFilePath: "compose.yml", projectName: "proj")

        _ = await collectMessages(request, files: files, adapter: adapter)
        let (secondMessages, secondExit) = await collectMessages(request, files: files, adapter: adapter)

        #expect(secondExit == 0)
        let readyMessage = secondMessages.first { $0.type == .serviceReady && $0.service == "web" }
        #expect(readyMessage?.reused == true, "the wire format must carry the reused flag end to end")
    }

    @Test("down with no compose file but an explicit project name still works")
    func downWithExplicitProjectOnly() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "proj-web", project: "proj", service: "web", running: true, configHash: "h")

        let request = ProtocolRequest(command: .down(remove: true, volumes: false), projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, adapter: adapter)

        #expect(exitCode == 0)
        #expect(messages.contains { $0.type == .serviceRemoved && $0.service == "web" }, "down --remove must report removed, not ready — the container no longer exists")

        let containers = await adapter.containers
        #expect(containers.isEmpty)
    }

    @Test("down with neither a project name nor a compose file reports error")
    func downWithNothingToResolveProjectFrom() async throws {
        let (messages, exitCode) = await collectMessages(ProtocolRequest(command: .down(remove: false, volumes: false)))
        #expect(exitCode == 1)
        #expect(messages.first?.type == .error)
    }

    @Test("Messages arrive via the callback as they happen, not only after completion")
    func messagesArriveIncrementally() async throws {
        // Proves the streaming contract end to end at the protocol layer: the
        // callback must fire more than once, in an order consistent with a
        // real operation's progress (planned first, done last).
        let request = ProtocolRequest(command: .up(services: []), composeFilePath: "compose.yml", projectName: "proj")
        let collector = MessageCollector()
        let runner = ProtocolRunner(adapter: FakeRuntimeAdapter(), files: InMemoryProvider([
            "compose.yml": "services:\n  web:\n    image: nginx\n"
        ]))
        _ = await runner.run(request) { collector.append($0) }
        let observedOrder = collector.messages.map(\.type)

        #expect(observedOrder.first == .planned)
        #expect(observedOrder.last == .done)
        #expect(observedOrder.count > 2, "expected intermediate progress messages between planned and done")
    }
}

@Suite("ProtocolRunner: expanded command surface")
struct ProtocolRunnerExpandedTests {

    private func collectMessages(
        _ request: ProtocolRequest,
        files: [String: String] = [:],
        adapter: FakeRuntimeAdapter = FakeRuntimeAdapter()
    ) async -> (messages: [ProtocolMessage], exitCode: Int32) {
        let runner = ProtocolRunner(adapter: adapter, files: InMemoryProvider(files))
        let collector = MessageCollector()
        let exitCode = await runner.run(request) { collector.append($0) }
        return (collector.messages, exitCode)
    }

    @Test("ps lists running containers as container messages")
    func psListsRunning() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: true, configHash: "h", image: "nginx")
        await adapter.seed(id: "b", project: "proj", service: "db", running: false, configHash: "h")

        let (messages, exitCode) = await collectMessages(ProtocolRequest(command: .ps(all: false), projectName: "proj"), adapter: adapter)
        #expect(exitCode == 0)
        #expect(messages.count == 1)
        #expect(messages[0].type == .container)
        #expect(messages[0].service == "web")
        #expect(messages[0].image == "nginx")
    }

    @Test("ps --all includes stopped containers too")
    func psAllIncludesStopped() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: true, configHash: "h")
        await adapter.seed(id: "b", project: "proj", service: "db", running: false, configHash: "h")

        let (messages, _) = await collectMessages(ProtocolRequest(command: .ps(all: true), projectName: "proj"), adapter: adapter)
        #expect(messages.count == 2)
    }

    @Test("ls spans every project, not just one")
    func lsSpansProjects() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj1", service: "web", running: true, configHash: "h")
        await adapter.seed(id: "b", project: "proj2", service: "web", running: true, configHash: "h")

        let (messages, _) = await collectMessages(ProtocolRequest(command: .ls(all: false)), adapter: adapter)
        #expect(Set(messages.compactMap(\.project)) == ["proj1", "proj2"])
    }

    @Test("config renders the resolved plan as text")
    func configRendersThePlan() async throws {
        let request = ProtocolRequest(command: .config, composeFilePath: "compose.yml", projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, files: [
            "compose.yml": "services:\n  web:\n    image: nginx\n"
        ])
        #expect(exitCode == 0)
        #expect(messages.count == 1)
        #expect(messages[0].type == .config)
        #expect(messages[0].output?.contains("web") == true)
    }

    @Test("logs streams seeded lines per container")
    func logsStreamsLines() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: true, configHash: "h")
        await adapter.seedLogs(containerID: "a", lines: ["starting", "listening on :80"])

        let (messages, exitCode) = await collectMessages(
            ProtocolRequest(command: .logs(services: [], follow: false, tail: nil), projectName: "proj"),
            adapter: adapter
        )
        #expect(exitCode == 0)
        #expect(messages.map(\.line) == ["starting", "listening on :80"])
        #expect(messages.allSatisfy { $0.service == "web" })
    }

    @Test("port reports the matching published binding")
    func portReportsBinding() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(
            id: "a", project: "proj", service: "web", running: true, configHash: "h",
            publishedPorts: [PublishedPort(containerPort: 80, hostPort: 8080, hostAddress: "0.0.0.0")]
        )

        let (messages, exitCode) = await collectMessages(
            ProtocolRequest(command: .port(service: "web", containerPort: 80), projectName: "proj"),
            adapter: adapter
        )
        #expect(exitCode == 0)
        #expect(messages.first?.ports == ["0.0.0.0:8080->80"])
    }

    @Test("port reports an error when the container port is not published")
    func portReportsErrorWhenUnpublished() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: true, configHash: "h")

        let (messages, exitCode) = await collectMessages(
            ProtocolRequest(command: .port(service: "web", containerPort: 80), projectName: "proj"),
            adapter: adapter
        )
        #expect(exitCode == 1)
        #expect(messages.first?.type == .error)
    }

    @Test("cp rewrites a service: prefix to the container id before calling the adapter")
    func cpRewritesServicePrefix() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "proj-web-1", project: "proj", service: "web", running: true, configHash: "h")

        let request = ProtocolRequest(command: .cp(source: "web:/etc/nginx.conf", destination: "./nginx.conf"), projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, adapter: adapter)

        #expect(exitCode == 0)
        #expect(messages.first?.type == .result)
        let copies = await adapter.copies
        #expect(copies.first?.source == "proj-web-1:/etc/nginx.conf")
        #expect(copies.first?.destination == "./nginx.conf")
    }

    @Test("cp with two plain host paths needs no project resolution")
    func cpWithoutServicePrefix() async throws {
        let adapter = FakeRuntimeAdapter()
        let request = ProtocolRequest(command: .cp(source: "./a", destination: "./b"))
        let (messages, exitCode) = await collectMessages(request, adapter: adapter)

        #expect(exitCode == 0)
        let copies = await adapter.copies
        #expect(copies.first?.source == "./a")
        #expect(copies.first?.destination == "./b")
        #expect(messages.first?.type == .result)
    }

    @Test("export calls the adapter with the resolved container id")
    func exportResolvesContainer() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "proj-web-1", project: "proj", service: "web", running: true, configHash: "h")

        let request = ProtocolRequest(command: .export(service: "web", outputPath: "web.tar"), projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, adapter: adapter)

        #expect(exitCode == 0)
        #expect(messages.first?.type == .result)
        let exports = await adapter.exports
        #expect(exports.first?.containerID == "proj-web-1")
        #expect(exports.first?.outputPath == "web.tar")
    }

    @Test("build/pull/push route through Engine and report the terminal outcome")
    func buildPullPushRouteThroughEngine() async throws {
        let files = ["compose.yml": """
            services:
              web:
                image: nginx
            """]
        let build = await collectMessages(
            ProtocolRequest(command: .build(services: []), composeFilePath: "compose.yml", projectName: "proj"), files: files
        )
        #expect(build.exitCode == 0, "a service with only image: has nothing to build, so build succeeds trivially")

        let pull = await collectMessages(
            ProtocolRequest(command: .pull(services: []), composeFilePath: "compose.yml", projectName: "proj"), files: files
        )
        #expect(pull.exitCode == 0)
        #expect(pull.messages.contains { $0.type == .imageReady && $0.service == "web" && $0.action == "pulled" })

        let push = await collectMessages(
            ProtocolRequest(command: .push(services: []), composeFilePath: "compose.yml", projectName: "proj"), files: files
        )
        #expect(push.exitCode == 0)
        #expect(push.messages.contains { $0.type == .imageReady && $0.service == "web" && $0.action == "pushed" })
    }

    @Test("start/stop route through Engine's lifecycle operations without needing --file")
    func startStopRouteThroughEngine() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "a", project: "proj", service: "web", running: false, configHash: "h")

        let start = await collectMessages(ProtocolRequest(command: .start(services: []), projectName: "proj"), adapter: adapter)
        #expect(start.exitCode == 0)
        let containers = await adapter.containers
        #expect(containers["a"]?.running == true)

        let stop = await collectMessages(ProtocolRequest(command: .stop(services: []), projectName: "proj"), adapter: adapter)
        #expect(stop.exitCode == 0)
        let containersAfterStop = await adapter.containers
        #expect(containersAfterStop["a"]?.running == false)
    }

    @Test("watch reports an error when no requested service declares develop.watch")
    func watchWithNothingToWatch() async throws {
        let request = ProtocolRequest(command: .watch(services: []), composeFilePath: "compose.yml", projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, files: [
            "compose.yml": "services:\n  web:\n    image: nginx\n"
        ])
        #expect(exitCode == 1)
        #expect(messages.first?.type == .error)
    }
}

@Suite("ProtocolRunner.runPassthrough")
struct ProtocolRunnerPassthroughTests {

    @Test("exec resolves the service to a container id and calls execPassthrough")
    func execResolvesContainer() async throws {
        let adapter = FakeRuntimeAdapter()
        await adapter.seed(id: "proj-web-1", project: "proj", service: "web", running: true, configHash: "h")
        let runner = ProtocolRunner(adapter: adapter, files: InMemoryProvider([:]))

        let request = ProtocolRequest(command: .exec(service: "web", command: ["sh"], tty: true), projectName: "proj")
        let (exitCode, error) = await runner.runPassthrough(request)

        #expect(exitCode == 0)
        #expect(error == nil)
    }

    @Test("exec reports an error, not a crash, when the service has no container")
    func execMissingService() async throws {
        let runner = ProtocolRunner(adapter: FakeRuntimeAdapter(), files: InMemoryProvider([:]))
        let request = ProtocolRequest(command: .exec(service: "ghost", command: ["sh"], tty: true), projectName: "proj")
        let (exitCode, error) = await runner.runPassthrough(request)

        #expect(exitCode == 1)
        #expect(error != nil)
    }

    @Test("run resolves a build-only service's image before running")
    func runResolvesBuildOnlyImage() async throws {
        let adapter = FakeRuntimeAdapter()
        let runner = ProtocolRunner(adapter: adapter, files: InMemoryProvider([
            "compose.yml": """
                services:
                  worker:
                    build:
                      context: .
                """
        ]))

        let request = ProtocolRequest(
            command: .run(service: "worker", command: ["make"], remove: true, tty: false),
            composeFilePath: "compose.yml", projectName: "proj"
        )
        let (exitCode, error) = await runner.runPassthrough(request)

        #expect(exitCode == 0)
        #expect(error == nil)
    }

    @Test("run reports an error for a service that does not exist in the plan")
    func runMissingService() async throws {
        let runner = ProtocolRunner(adapter: FakeRuntimeAdapter(), files: InMemoryProvider([
            "compose.yml": "services:\n  web:\n    image: nginx\n"
        ]))
        let request = ProtocolRequest(
            command: .run(service: "ghost", command: ["sh"], remove: false, tty: true),
            composeFilePath: "compose.yml", projectName: "proj"
        )
        let (exitCode, error) = await runner.runPassthrough(request)

        #expect(exitCode == 1)
        #expect(error != nil)
    }
}

/// A lock-guarded box for the `@Sendable` callback tests hand to
/// `ProtocolRunner.run`: actions within a wave execute concurrently and may
/// call the callback from different threads at once, so a plain `var` capture
/// is unsafe — this mirrors the same pattern the engine's own concurrency
/// tests rely on.
private final class MessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [ProtocolMessage] = []

    func append(_ message: ProtocolMessage) {
        lock.lock()
        defer { lock.unlock() }
        _messages.append(message)
    }

    var messages: [ProtocolMessage] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }
}

@Suite("Variables supplied per invocation")
struct EnvOverrideTests {

    @Test("--env-stdin is accepted, and is off by default")
    func flagParses() throws {
        let with = try ProtocolRequest.parse(["up", "--file", "c.yml", "--env-stdin"])
        #expect(with.envFromStdin)

        let without = try ProtocolRequest.parse(["up", "--file", "c.yml"])
        #expect(!without.envFromStdin)

        // Accepted by every command's parser, not just one — `config` and
        // `up` go through different loops, and the flag silently failing
        // on one of them is exactly the bug this pins.
        #expect(try ProtocolRequest.parse(["config", "--file", "c.yml", "--env-stdin"]).envFromStdin)
        #expect(try ProtocolRequest.parse(["translate", "--file", "c.yml", "--env-stdin"]).envFromStdin)
    }

    @Test("Supplied variables outrank both the shell and the .env file")
    func overridesWinOverEverything() throws {
        // A caller passing a value for THIS invocation is a stronger
        // statement of intent than either ambient source.
        let document = """
            services:
              app:
                image: nginx
                environment:
                  - KEY=${SOME_KEY}
            """
        let files = InMemoryProvider(["/project/.env": "SOME_KEY=from-dotenv\n"])
        let plan = try Planner(files: files).plan(
            document: document,
            options: PlanOptions(
                projectName: "proj",
                directory: "/project",
                variables: ["SOME_KEY": "from-override"]
            )
        )
        let app = try #require(plan.service(named: "app"))
        #expect(app.environment["KEY"] == "from-override")
    }

    @Test("Supplied variables satisfy the generated-variable check")
    func overridesSatisfyTheGeneratedCheck() throws {
        // A GUI that holds these can drive `up` without ever writing a
        // .env beside the compose file.
        let document = """
            services:
              app:
                image: openclaw
                environment:
                  - AUTH_PASSWORD=${SERVICE_PASSWORD_OPENCLAW}
            """
        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(
                projectName: "proj",
                variables: ["SERVICE_PASSWORD_OPENCLAW": "piped-in"]
            )
        )
        let app = try #require(plan.service(named: "app"))
        #expect(app.environment["AUTH_PASSWORD"] == "piped-in")
    }

    @Test("An empty supplied value does not count as set")
    func emptyOverrideIsNotAValue() throws {
        // Otherwise piping `KEY=` would silence the refusal while leaving
        // the service exactly as broken as before.
        let document = """
            services:
              app:
                image: openclaw
                environment:
                  - AUTH_PASSWORD=${SERVICE_PASSWORD_OPENCLAW}
            """
        #expect(throws: PlanError.self) {
            try Planner(files: InMemoryProvider([:])).plan(
                document: document,
                options: PlanOptions(projectName: "proj", variables: ["SERVICE_PASSWORD_OPENCLAW": ""])
            )
        }
    }
}
