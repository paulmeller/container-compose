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
import ComposeCore

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
    /// Uses the product's own naming rather than rebuilding the string.
    /// Rebuilding it is exactly how this leaked: the teardown wrote
    /// `\(projectName)_default` without the lowercasing the planner
    /// applies, so it asked to delete a name that had never existed and
    /// silently removed nothing, once per test.
    static func removeProjectNetwork(_ projectName: String) {
        removeNetwork(ProjectNaming.defaultNetworkName(project: projectName))
    }

    private static func exists(_ name: String) -> Bool {
        guard let result = try? ContainerCLI.run(["network", "list"]) else { return false }
        return result.stdout
            .split(separator: "\n")
            .dropFirst()
            .contains { $0.split(separator: " ").first.map(String.init) == name }
    }
}
