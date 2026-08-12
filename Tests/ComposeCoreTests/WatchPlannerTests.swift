//
//  WatchPlannerTests.swift
//  container-compose
//
//  Pure snapshot-diffing logic — no filesystem, no daemon, mirroring how
//  ReconcilerTests exercises Reconciler with hand-built inputs.
//

import Testing
import Foundation
import ComposeCore

@Suite("WatchPlanner")
struct WatchPlannerTests {

    @Test("A path present only in the current snapshot is added")
    func addedPath() throws {
        let changes = WatchPlanner.diff(previous: [:], current: ["/src/a.js": "1"])
        #expect(changes == [WatchChange(path: "/src/a.js", kind: .added)])
    }

    @Test("A path with a different signature is modified")
    func modifiedPath() throws {
        let changes = WatchPlanner.diff(previous: ["/src/a.js": "1"], current: ["/src/a.js": "2"])
        #expect(changes == [WatchChange(path: "/src/a.js", kind: .modified)])
    }

    @Test("A path with the same signature produces no change")
    func unchangedPath() throws {
        let changes = WatchPlanner.diff(previous: ["/src/a.js": "1"], current: ["/src/a.js": "1"])
        #expect(changes.isEmpty)
    }

    @Test("A path present only in the previous snapshot is removed")
    func removedPath() throws {
        let changes = WatchPlanner.diff(previous: ["/src/a.js": "1"], current: [:])
        #expect(changes == [WatchChange(path: "/src/a.js", kind: .removed)])
    }

    @Test("Multiple changes are sorted by path for a deterministic result")
    func sortedByPath() throws {
        let changes = WatchPlanner.diff(
            previous: [:],
            current: ["/src/z.js": "1", "/src/a.js": "1"]
        )
        #expect(changes.map(\.path) == ["/src/a.js", "/src/z.js"])
    }

    @Test("A rule's ignore list excludes a matching substring")
    func ignoreExcludesMatch() throws {
        let rule = WatchRule(path: "src", action: "sync", target: "/app", ignore: ["node_modules"])
        #expect(WatchPlanner.isIgnored("src/node_modules/x.js", by: rule))
        #expect(!WatchPlanner.isIgnored("src/app.js", by: rule))
    }

    @Test("A rule with no ignore list excludes nothing")
    func noIgnoreListExcludesNothing() throws {
        let rule = WatchRule(path: "src", action: "sync", target: "/app")
        #expect(!WatchPlanner.isIgnored("src/anything.js", by: rule))
    }

    @Test("A leading ./ is stripped, matching what a real directory walk normalizes its own paths to")
    func normalizedRulePathStripsDotPrefix() throws {
        // Regression: caught live. `URL.appendingPathComponent("./src")`
        // keeps the literal "./", but FileManager's enumerator never returns
        // paths containing one — the mismatch silently truncated every
        // synced filename by 2 characters (`greeting.txt` -> `reeting.txt`).
        #expect(WatchPlanner.normalizedRulePath("./src") == "src")
    }

    @Test("A path with no . components passes through unchanged")
    func normalizedRulePathUnchanged() throws {
        #expect(WatchPlanner.normalizedRulePath("src/nested") == "src/nested")
    }

    @Test("A bare . normalizes to an empty relative path")
    func normalizedRulePathBareDot() throws {
        #expect(WatchPlanner.normalizedRulePath(".") == "")
    }

    @Test("A . component nested mid-path is also stripped")
    func normalizedRulePathStripsNestedDot() throws {
        #expect(WatchPlanner.normalizedRulePath("src/./nested") == "src/nested")
    }
}
