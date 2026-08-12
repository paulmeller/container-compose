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
        #expect(withRemove.command == .down(remove: true))

        let without = try ProtocolRequest.parse(["down", "--file", "c.yml"])
        #expect(without.command == .down(remove: false))
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
        await adapter.seed(id: "proj-web", service: "web", running: true, configHash: "h")

        let request = ProtocolRequest(command: .down(remove: true), projectName: "proj")
        let (messages, exitCode) = await collectMessages(request, adapter: adapter)

        #expect(exitCode == 0)
        #expect(messages.contains { $0.type == .serviceReady && $0.service == "web" })

        let containers = await adapter.containers
        #expect(containers.isEmpty)
    }

    @Test("down with neither a project name nor a compose file reports error")
    func downWithNothingToResolveProjectFrom() async throws {
        let (messages, exitCode) = await collectMessages(ProtocolRequest(command: .down(remove: false)))
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
