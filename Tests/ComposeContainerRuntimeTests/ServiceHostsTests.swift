//
//  ServiceHostsTests.swift
//  container-compose
//
//  Compose's contract is that a service reaches its peers by service name.
//  Apple's runtime registers containers under their own name only
//  (`openclaw-browser.test`) and has no alias mechanism — no
//  `--network-alias`, no `--add-host`, no alias field on `--network` — so
//  a compose file saying `http://browser:9223` resolved nothing, and the
//  service that depended on it died at startup.
//
//  The addresses live in a per-project hosts file bind-mounted over
//  /etc/hosts. These tests cover the file's content rules, which are what
//  make the difference between a peer resolving and resolving to something
//  that has since been handed to another container.
//

import Testing
import Foundation
@testable import ComposeContainerRuntime

@Suite("Service-name hosts file")
struct ServiceHostsTests {
    /// Each test gets its own project name so they cannot tread on each
    /// other's file, or on a real project's.
    private func scratchProject(_ label: String) -> String {
        "cc-hosts-test-\(label)-\(UUID().uuidString.prefix(8))"
    }

    private func cleanUp(_ project: String) {
        if let url = try? ContainerRuntimeAdapter.hostsFile(projectName: project) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    @Test("A new project's hosts file still has localhost in it")
    func preambleIsWritten() throws {
        let project = scratchProject("preamble")
        defer { cleanUp(project) }

        let adapter = ContainerRuntimeAdapter()
        let url = try adapter.ensureHostsFile(projectName: project)
        let contents = try String(contentsOf: url, encoding: .utf8)

        // Mounting a file over /etc/hosts replaces what the image shipped.
        // Without this, `localhost` stops resolving inside every container
        // of the project — a far worse failure than the one being fixed.
        #expect(contents.contains("127.0.0.1 localhost"))
    }

    @Test("A started service is reachable by its service name and its container name")
    func recordsBothNames() throws {
        let project = scratchProject("names")
        defer { cleanUp(project) }

        let adapter = ContainerRuntimeAdapter()
        try adapter.recordServiceAddress(projectName: project, service: "browser", address: "192.168.95.2")
        let contents = try String(contentsOf: ContainerRuntimeAdapter.hostsFile(projectName: project), encoding: .utf8)

        // The service name is the one Compose promises. The container name
        // is kept too, since that is what the runtime's own DNS answers to
        // and existing files may already use it.
        #expect(contents.contains("192.168.95.2 browser \(project)-browser"))
        #expect(contents.contains("127.0.0.1 localhost"))
    }

    @Test("Re-upping replaces an address rather than leaving both")
    func replacesStaleAddress() throws {
        let project = scratchProject("restale")
        defer { cleanUp(project) }

        let adapter = ContainerRuntimeAdapter()
        try adapter.recordServiceAddress(projectName: project, service: "db", address: "192.168.95.2")
        try adapter.recordServiceAddress(projectName: project, service: "db", address: "192.168.95.7")
        let contents = try String(contentsOf: ContainerRuntimeAdapter.hostsFile(projectName: project), encoding: .utf8)

        // The runtime hands out a different address on each up. Two lines
        // for one name is worse than none: resolution would pick the first,
        // which now belongs to whatever the runtime gave it to next.
        #expect(!contents.contains("192.168.95.2"))
        #expect(contents.contains("192.168.95.7 db \(project)-db"))
        let dbLines = contents.split(separator: "\n").filter { $0.contains(" db ") || $0.hasSuffix(" db") }
        #expect(dbLines.count == 1)
    }

    @Test("Several services coexist in one file")
    func multipleServices() throws {
        let project = scratchProject("several")
        defer { cleanUp(project) }

        let adapter = ContainerRuntimeAdapter()
        try adapter.recordServiceAddress(projectName: project, service: "browser", address: "192.168.95.2")
        try adapter.recordServiceAddress(projectName: project, service: "openclaw", address: "192.168.95.3")
        let contents = try String(contentsOf: ContainerRuntimeAdapter.hostsFile(projectName: project), encoding: .utf8)

        // One shared file per project is what lets a container started
        // earlier see a peer that started later: libc re-reads /etc/hosts
        // on every lookup, so no restart is needed.
        #expect(contents.contains("192.168.95.2 browser"))
        #expect(contents.contains("192.168.95.3 openclaw"))
        #expect(contents.contains("127.0.0.1 localhost"))
    }

    @Test("A service named after a loopback alias cannot evict the preamble")
    func serviceNameDoesNotClobberLocalhost() throws {
        let project = scratchProject("clobber")
        defer { cleanUp(project) }

        let adapter = ContainerRuntimeAdapter()
        try adapter.recordServiceAddress(projectName: project, service: "web", address: "127.0.0.1")
        try adapter.recordServiceAddress(projectName: project, service: "web", address: "192.168.95.4")
        let contents = try String(contentsOf: ContainerRuntimeAdapter.hostsFile(projectName: project), encoding: .utf8)

        // Replacement matches on the name fields, never the address, so a
        // service that once held 127.0.0.1 does not take the localhost line
        // with it when it moves.
        #expect(contents.contains("127.0.0.1 localhost"))
        #expect(contents.contains("192.168.95.4 web"))
    }

    @Test("A container's address is read from its labels, not guessed from its name")
    func addressDecodedFromLabels() throws {
        // A project name may itself contain a hyphen, so splitting
        // `my-app-web` into project and service is a guess. The labels say
        // which is which.
        let payload = """
        [{"configuration":{"id":"my-app-web","labels":{"com.docker.compose.project":"my-app","com.docker.compose.service":"web"}},
          "status":{"state":"running","networks":[{"ipv4Address":"192.168.95.9/24"}]}}]
        """
        let entries = try JSONDecoder().decode([WireContainerEntry].self, from: Data(payload.utf8))
        let entry = try #require(entries.first)

        #expect(entry.configuration.labels?["com.docker.compose.project"] == "my-app")
        #expect(entry.configuration.labels?["com.docker.compose.service"] == "web")
        #expect(entry.status.networks?.first?.ipv4Address == "192.168.95.9/24")
    }

    @Test("A stopped container reports no address, which is why recording waits for start")
    func stoppedContainerHasNoAddress() throws {
        let payload = """
        [{"configuration":{"id":"my-app-web","labels":{"com.docker.compose.project":"my-app","com.docker.compose.service":"web"}},
          "status":{"state":"stopped","networks":[]}}]
        """
        let entries = try JSONDecoder().decode([WireContainerEntry].self, from: Data(payload.utf8))
        let entry = try #require(entries.first)

        // Addresses are assigned at start, not create — so the file cannot
        // be generated ahead of time, and every service must be recorded as
        // it comes up.
        #expect(entry.status.networks?.isEmpty == true)
    }
}
