//
//  CapabilityLiveTests.swift
//  container-compose
//
//  `CapabilityManifestTests` checks the manifest is internally coherent.
//  This checks it against the runtime actually installed: every flag the
//  manifest promises to translate a compose key into has to be a flag
//  `container run` accepts.
//
//  Without this, a flag renamed or dropped by a runtime release keeps
//  being emitted, and the failure arrives as an opaque usage error from
//  a child process at `create` time — attributed to the compose file
//  rather than to the manifest that is now wrong about the runtime.
//

import Testing
import Foundation
@testable import ComposeCore
@testable import ComposeContainerRuntime

@Suite("Capability manifest against the installed runtime")
struct CapabilityLiveTests {
    private static var daemonAvailable: Bool {
        (try? ContainerCLI.run(["system", "status"]))?.succeeded == true
    }

    /// Every flag `container run --help` lists, including short forms.
    private static func advertisedFlags() -> Set<String> {
        guard let help = try? ContainerCLI.run(["run", "--help"]) else { return [] }
        var flags: Set<String> = []
        for line in help.stdout.split(separator: "\n") {
            // Flags appear at the start of a help line, `-x, --long <v>`
            // or `--long <v>`; anything after the description begins is
            // prose and must not be scraped.
            for token in line.split(whereSeparator: { $0 == " " || $0 == "," }) {
                guard token.hasPrefix("-") else { break }
                flags.insert(String(token))
            }
        }
        return flags
    }

    @Test("Every flag the manifest maps to is one the runtime accepts")
    func mappedFlagsExist() throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }
        let advertised = Self.advertisedFlags()
        try #require(!advertised.isEmpty, "could not read `container run --help`")

        let capabilities = RuntimeCapabilities.appleContainer
        let mapped = capabilities.listFlags.merging(capabilities.scalarFlags) { a, _ in a }
            .merging(capabilities.booleanFlags) { a, _ in a }

        for (key, flag) in mapped.sorted(by: { $0.key < $1.key }) {
            #expect(
                advertised.contains(flag),
                "manifest maps `\(key)` to `\(flag)`, which this runtime does not advertise"
            )
        }
    }

    @Test("A key the manifest calls unsupported has no obvious flag going begging")
    func unsupportedKeysHaveNoObviousFlag() throws {
        guard Self.daemonAvailable else {
            print("Skipping: `container` daemon is not available.")
            return
        }
        let advertised = Self.advertisedFlags()
        try #require(!advertised.isEmpty)

        // Weak on purpose: a compose key does not always share a name
        // with its flag, so this only flags the exact-match case — a key
        // declared unsupported while `--<key>` sits right there. That is
        // how a runtime gaining a feature would otherwise go unnoticed,
        // with the manifest still telling users it cannot be done.
        for key in RuntimeCapabilities.appleContainer.unsupported.keys {
            let candidate = "--" + key.replacingOccurrences(of: "_", with: "-")
            #expect(
                !advertised.contains(candidate),
                "`\(key)` is listed unsupported, but this runtime advertises `\(candidate)`"
            )
        }
    }
}
