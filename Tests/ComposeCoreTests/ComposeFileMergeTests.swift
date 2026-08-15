//
//  ComposeFileMergeTests.swift
//  container-compose
//
//  `-f base.yml -f override.yml` exists so a template can stay pristine
//  while a local file adjusts it. The motivating case is an app installed
//  from a catalog: the template is refetched on every reinstall, so any
//  edit made directly to it is lost — a `mem_limit` raised to stop a
//  service being OOM-killed, or a `ports` mapping added because the
//  template assumed a reverse proxy that is not there.
//
//  The rules are not uniform, which is the whole reason these are pinned:
//  scalars take the last value, ports and the other multi-value options
//  concatenate, and environment merges per key in either of the two forms
//  it can be written in.
//

import Testing
import Foundation
import Yams
@testable import ComposeCore

@Suite("Compose file merging")
struct ComposeFileMergeTests {
    private let base = """
    services:
      web:
        image: "nginx:alpine"
        ports:
          - "8080:80"
        environment:
          - KEEP=base
          - REPLACED=base
      untouched:
        image: "redis:7"
    volumes:
      data: {}
    """

    @Test("A single file is returned untouched, not round-tripped")
    func singleFileIsUnchanged() throws {
        // The common case must not pay for — or risk — a parse and re-dump
        // it is not using.
        #expect(try ComposeFileMerge.merge(documents: [base]) == base)
    }

    @Test("An override adds a key without disturbing what the base declared")
    func overrideAddsKeys() throws {
        let override = """
        services:
          web:
            mem_limit: 4g
        """
        let merged = try ComposeFileMerge.merge(documents: [base, override])
        let root = try #require(Yams.load(yaml: merged) as? [String: Any])
        let services = try #require(root["services"] as? [String: Any])
        let web = try #require(services["web"] as? [String: Any])

        #expect("\(web["mem_limit"] ?? "")" == "4g")
        #expect("\(web["image"] ?? "")" == "nginx:alpine")
        // A service the override never mentions must survive intact.
        #expect(services["untouched"] != nil)
        #expect(root["volumes"] != nil)
    }

    @Test("Ports concatenate rather than replace")
    func portsConcatenate() throws {
        let override = """
        services:
          web:
            ports:
              - "9090:9090"
        """
        let merged = try ComposeFileMerge.merge(documents: [base, override])
        let root = try #require(Yams.load(yaml: merged) as? [String: Any])
        let web = try #require((root["services"] as? [String: Any])?["web"] as? [String: Any])
        let portValues = try #require(web["ports"] as? [Any])
        let ports = portValues.map { "\($0)" }

        // A multi-value option publishes both, matching Compose: an
        // override adding a port is adding one, not discarding the rest.
        #expect(ports.contains("8080:80"))
        #expect(ports.contains("9090:9090"))
    }

    @Test("List-form environment merges per key, keeping what the override does not restate")
    func listEnvironmentMergesByKey() throws {
        let override = """
        services:
          web:
            environment:
              - REPLACED=override
              - ADDED=new
        """
        let merged = try ComposeFileMerge.merge(documents: [base, override])
        let root = try #require(Yams.load(yaml: merged) as? [String: Any])
        let web = try #require((root["services"] as? [String: Any])?["web"] as? [String: Any])
        let environmentValues = try #require(web["environment"] as? [Any])
        let environment = environmentValues.map { "\($0)" }

        // The bug this pins: matching only the mapping form let a
        // list-form override replace the whole list, so KEEP — which the
        // override never mentioned — silently disappeared.
        #expect(environment.contains("KEEP=base"))
        #expect(environment.contains("REPLACED=override"))
        #expect(environment.contains("ADDED=new"))
        #expect(!environment.contains("REPLACED=base"))
    }

    @Test("A scalar takes the last file's value")
    func scalarsTakeTheLastValue() throws {
        let override = """
        services:
          web:
            image: "nginx:1.27"
        """
        let merged = try ComposeFileMerge.merge(documents: [base, override])
        let root = try #require(Yams.load(yaml: merged) as? [String: Any])
        let web = try #require((root["services"] as? [String: Any])?["web"] as? [String: Any])

        #expect("\(web["image"] ?? "")" == "nginx:1.27")
    }

    @Test("An override may introduce a service the base never had")
    func overrideAddsService() throws {
        let override = """
        services:
          sidecar:
            image: "busybox"
        """
        let merged = try ComposeFileMerge.merge(documents: [base, override])
        let root = try #require(Yams.load(yaml: merged) as? [String: Any])
        let services = try #require(root["services"] as? [String: Any])

        #expect(services["sidecar"] != nil)
        #expect(services["web"] != nil)
    }

    @Test("An empty override file is legitimate, not an error")
    func emptyOverrideIsFine() throws {
        // The app writes the override before the user has adjusted
        // anything, so "exists but says nothing" is a normal state.
        let merged = try ComposeFileMerge.merge(documents: [base, "\n"])
        let root = try #require(Yams.load(yaml: merged) as? [String: Any])
        #expect((root["services"] as? [String: Any])?["web"] != nil)
    }

    @Test("A file that is not a mapping is refused by number")
    func malformedFileIsNamed() throws {
        // Merging silently past a broken file would plan the wrong
        // project, so this fails and says which file to look at.
        #expect(throws: ComposeFileMerge.MergeError.self) {
            try ComposeFileMerge.merge(documents: [base, "- not\n- a mapping\n"])
        }
    }
}
