//
//  LiveTeardown.swift
//  container-compose
//
//  Deleting a container returns before the runtime has released the
//  network it was attached to, so a `network delete` issued immediately
//  afterwards fails with the network still in use. Every live suite
//  swallowed that failure with `try?`, so each test quietly left its
//  `<project>_default` behind.
//
//  That is not merely untidy. Every network is a launchd service the
//  daemon starts and waits on at boot, so a few hundred accumulated runs
//  produce a daemon that cannot come up — which is exactly what happened,
//  taking every running container with it.
//

import Foundation
@testable import ComposeContainerRuntime

enum LiveTeardown {
    /// Delete a network, retrying while the runtime still considers it in
    /// use. Bounded: teardown must not hang a test run, and a network that
    /// genuinely will not go is better reported by the next run's leak
    /// than by a suite that never finishes.
    static func removeNetwork(_ name: String, attempts: Int = 10, delay: TimeInterval = 0.3) {
        for attempt in 0..<attempts {
            if (try? ContainerCLI.run(["network", "delete", name])) != nil { return }
            // Already gone is success, not a failure worth retrying.
            if !exists(name) { return }
            if attempt < attempts - 1 { Thread.sleep(forTimeInterval: delay) }
        }
    }

    /// Delete the network a project brought up. Scoped to the one project
    /// rather than swept by prefix: these suites run in parallel, and a
    /// sweep could take a network a concurrent test was still setting up.
    ///
    /// Lowercased, because the planner lowercases derived network names —
    /// the runtime rejects an uppercase one. These suites name projects
    /// after a UUID, whose hex is uppercase, so deleting
    /// `\(projectName)_default` verbatim asked for a name that had never
    /// existed and silently removed nothing.
    static func removeProjectNetwork(_ projectName: String) {
        removeNetwork("\(projectName.lowercased())_default")
    }

    private static func exists(_ name: String) -> Bool {
        guard let result = try? ContainerCLI.run(["network", "list"]) else { return false }
        return result.stdout
            .split(separator: "\n")
            .dropFirst()
            .contains { $0.split(separator: " ").first.map(String.init) == name }
    }
}
