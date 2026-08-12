//
//  CLIRendererTests.swift
//  container-compose
//
//  Pure formatting logic, tested with hand-built ProtocolMessages — no
//  protocol runner, no engine, no daemon, no process. Same fast-test pattern
//  as every other layer of this project.
//

import Testing
import Foundation
import ComposeCore
import ComposeProtocol
@testable import ComposeCLIKit

@Suite("CLIRenderer")
struct CLIRendererTests {

    @Test("planned reports the service count and wave breakdown")
    func plannedMessage() throws {
        let renderer = CLIRenderer()
        let line = renderer.render(ProtocolMessage(type: .planned, services: ["db", "api"], waves: [["db"], ["api"]]))

        let text = try #require(line)
        #expect(text.contains("2 services"))
        #expect(text.contains("wave 1: db"))
        #expect(text.contains("wave 2: api"))
    }

    @Test("A single service uses singular wording")
    func singularService() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .planned, services: ["web"], waves: [["web"]])))
        #expect(line.contains("1 service"))
        #expect(!line.contains("1 services"))
    }

    @Test("serviceReady distinguishes reused from freshly created")
    func serviceReadyReusedVsFresh() throws {
        let renderer = CLIRenderer()
        // Seed the column width the way a real stream would, via .planned first.
        _ = renderer.render(ProtocolMessage(type: .planned, services: ["web"], waves: [["web"]]))

        let reused = try #require(renderer.render(ProtocolMessage(type: .serviceReady, service: "web", container: "proj-web", reused: true)))
        let fresh = try #require(renderer.render(ProtocolMessage(type: .serviceReady, service: "web", container: "proj-web", reused: false)))

        #expect(reused.contains("reused"))
        #expect(!reused.contains("ready "), "must not say both 'reused' and 'ready' for the same event")
        #expect(fresh.contains("ready"))
        #expect(!fresh.contains("reused"))
    }

    @Test("serviceReady includes the container name")
    func serviceReadyIncludesContainer() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .serviceReady, service: "web", container: "myproj-web", reused: false)))
        #expect(line.contains("myproj-web"))
    }

    @Test("serviceStopped reads as stopped, distinct from ready or removed")
    func serviceStoppedRendering() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .serviceStopped, service: "web", container: "proj-web")))
        #expect(line.contains("stopped"))
        #expect(line.contains("proj-web"))
        #expect(!line.contains("ready"))
        #expect(!line.contains("removed"))
    }

    @Test("serviceRemoved reads as removed, distinct from ready or stopped")
    func serviceRemovedRendering() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .serviceRemoved, service: "web", container: "proj-web")))
        #expect(line.contains("removed"))
        #expect(!line.contains("ready"))
        #expect(!line.contains("stopped"))
    }

    @Test("imageReady renders the action (built/pulled/pushed) and the image reference")
    func imageReadyRendering() throws {
        let renderer = CLIRenderer()
        let built = try #require(renderer.render(ProtocolMessage(type: .imageReady, service: "web", image: "proj/web:latest", action: "built")))
        #expect(built.contains("built"))
        #expect(built.contains("proj/web:latest"))

        let pulled = try #require(renderer.render(ProtocolMessage(type: .imageReady, service: "web", image: "nginx:alpine", action: "pulled")))
        #expect(pulled.contains("pulled"))

        let pushed = try #require(renderer.render(ProtocolMessage(type: .imageReady, service: "web", image: "registry/web:1.0", action: "pushed")))
        #expect(pushed.contains("pushed"))
    }

    @Test("serviceFailed surfaces the reason")
    func serviceFailedShowsReason() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .serviceFailed, service: "web", reason: "image not found")))
        #expect(line.contains("FAILED"))
        #expect(line.contains("image not found"))
    }

    @Test("serviceSkipped names the reason, distinguishing it from a failure")
    func serviceSkippedIsDistinctFromFailed() throws {
        let renderer = CLIRenderer()
        let skipped = try #require(renderer.render(ProtocolMessage(type: .serviceSkipped, service: "web", reason: "dependencyFailed")))
        let failed = try #require(renderer.render(ProtocolMessage(type: .serviceFailed, service: "web", reason: "dependencyFailed")))
        #expect(skipped.contains("skipped"))
        #expect(!skipped.contains("FAILED"), "a skipped service must not read as a failed one")
        #expect(failed.contains("FAILED"))
    }

    @Test("done reports success and the per-outcome counts")
    func doneMessageSuccess() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .done, success: true, ready: ["a", "b"], failed: [], skipped: [])))
        #expect(line.contains("succeeded"))
        #expect(line.contains("2 ready"))
        #expect(line.contains("0 failed"))
    }

    @Test("done reports failure distinctly from success")
    func doneMessageFailure() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(type: .done, success: false, ready: ["a"], failed: ["b"], skipped: ["c"])))
        #expect(line.contains("failed"))
        #expect(!line.contains("succeeded"))
        #expect(line.contains("1 ready"))
        #expect(line.contains("1 failed"))
        #expect(line.contains("1 skipped"))
    }

    @Test("error renders the message text, not a raw dump of the struct")
    func errorMessage() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.errorMessage("compose file not found at 'x.yml'")))
        #expect(line.contains("compose file not found"))
    }

    @Test("Service names longer than the widest planned name still render, unpadded past their own length")
    func columnWidthNeverTruncates() throws {
        let renderer = CLIRenderer()
        _ = renderer.render(ProtocolMessage(type: .planned, services: ["a"], waves: [["a"]]))
        // A service NOT in the original plan (defensive: should not happen,
        // but rendering must never crash or truncate if it does).
        let line = try #require(renderer.render(ProtocolMessage(type: .serviceState, service: "unexpectedly-long-service-name", state: "starting")))
        #expect(line.contains("unexpectedly-long-service-name"))
    }

    @Test("container renders project/service, state, id, image and ports")
    func containerRendering() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(ProtocolMessage(
            type: .container, service: "web", state: "running", container: "proj-web",
            project: "proj", image: "nginx:latest", ports: ["0.0.0.0:8080->80"]
        )))
        #expect(line.contains("proj/web"))
        #expect(line.contains("running"))
        #expect(line.contains("proj-web"))
        #expect(line.contains("nginx:latest"))
        #expect(line.contains("0.0.0.0:8080->80"))
    }

    @Test("config renders the raw output text verbatim")
    func configRendering() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.configMessage("{\"projectName\":\"proj\"}")))
        #expect(line.contains("projectName"))
    }

    @Test("log lines are prefixed per service")
    func logRendering() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.logMessage(service: "web", line: "listening on :80")))
        #expect(line.contains("web"))
        #expect(line.contains("listening on :80"))
    }

    @Test("output renders a service-prefixed text blob when a service is present")
    func outputRenderingWithService() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.outputMessage(service: "web", text: "PID   COMMAND\n1     nginx")))
        #expect(line.contains("web:"))
        #expect(line.contains("PID   COMMAND"))
    }

    @Test("output with no service (stats across many containers) omits a prefix")
    func outputRenderingWithoutService() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.outputMessage(text: "CONTAINER   CPU\nweb   0.0%")))
        #expect(line == "CONTAINER   CPU\nweb   0.0%")
    }

    @Test("result renders its text verbatim")
    func resultRendering() throws {
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.resultMessage("copied a -> b")))
        #expect(line.contains("copied a -> b"))
    }

    @Test("capabilities lists supported, unsupported and partial keys")
    func capabilitiesRendering() throws {
        let capabilities = RuntimeCapabilities(
            listFlags: ["cap_add": "--cap-add"],
            unsupported: ["restart": "no restart-policy flag exists"],
            partial: ["deploy": (reason: "orchestrator concepts", supported: ["resources.limits.cpus"])]
        )
        let renderer = CLIRenderer()
        let line = try #require(renderer.render(.capabilitiesMessage(capabilities)))

        #expect(line.contains("cap_add"))
        #expect(line.contains("restart"))
        #expect(line.contains("no restart-policy flag exists"))
        #expect(line.contains("deploy"))
        #expect(line.contains("resources.limits.cpus"))
    }
}
