//
//  CapabilityManifestTests.swift
//  container-compose
//
//  The manifest is a contract: a consumer reads it to decide what to
//  warn about before running anything. Nothing verified it, and it drifted
//  into stating things that were not true —
//
//    `links`        "superseded by networks; service names already
//                   resolve" — service names did NOT resolve until
//                   service-name DNS was implemented.
//    `extra_hosts`  listed as partially supported, claiming entries "are
//                   written into a generated /etc/hosts". Nothing read
//                   the key at all; it appeared only in merge rules.
//    `hostname`     mapped to `--name`, which sets a container's identity
//                   rather than its hostname — and `createContainer`
//                   already passes `--name`. A service declaring
//                   `hostname:` emitted a second one.
//
//  A manifest that lies is worse than no manifest, because a consumer
//  plans around it. These pin the structural claims it can be held to
//  without a runtime; `CapabilityLiveTests` checks the flags are real.
//

import Testing
@testable import ComposeCore

@Suite("Capability manifest")
struct CapabilityManifestTests {
    private let capabilities = RuntimeCapabilities.appleContainer

    private var allFlagKeys: [String] {
        Array(capabilities.listFlags.keys)
            + Array(capabilities.scalarFlags.keys)
            + Array(capabilities.booleanFlags.keys)
    }

    private var allFlags: [String] {
        Array(capabilities.listFlags.values)
            + Array(capabilities.scalarFlags.values)
            + Array(capabilities.booleanFlags.values)
    }

    /// Flags `createContainer` builds itself, from the plan. A compose key
    /// mapping to one of these does not "add" a flag — it emits a second
    /// copy of one the adapter has already decided, which is how
    /// `hostname` came to override a container's identity.
    private let reservedByTheAdapter: Set<String> = ["--name", "-l", "-e", "-p", "-v", "--network"]

    @Test("No compose key maps onto a flag the adapter already sets itself")
    func noKeyCollidesWithAdapterFlags() {
        for (key, flag) in capabilities.scalarFlags {
            #expect(!reservedByTheAdapter.contains(flag), "\(key) maps to \(flag), which createContainer already passes")
        }
        for (key, flag) in capabilities.listFlags {
            #expect(!reservedByTheAdapter.contains(flag), "\(key) maps to \(flag), which createContainer already passes")
        }
        for (key, flag) in capabilities.booleanFlags {
            #expect(!reservedByTheAdapter.contains(flag), "\(key) maps to \(flag), which createContainer already passes")
        }
    }

    @Test("A key is claimed by exactly one map")
    func keysDoNotOverlap() {
        // Two maps claiming one key means the value is rendered twice, or
        // rendered in whichever shape happens to be read first.
        let keys = allFlagKeys
        #expect(Set(keys).count == keys.count, "a compose key appears in more than one flag map")
    }

    @Test("Nothing is both supported and unsupported")
    func supportedKeysAreNotAlsoUnsupported() {
        // This is the shape the `extra_hosts` claim had: listed as
        // handled while nothing handled it. Being in neither is honest;
        // being in both is a contradiction a consumer cannot resolve.
        for key in allFlagKeys {
            #expect(capabilities.unsupported[key] == nil, "\(key) is mapped to a flag AND listed unsupported")
        }
    }

    @Test("Nothing is both partially supported and unsupported")
    func partialKeysAreNotAlsoUnsupported() {
        for key in capabilities.partial.keys {
            #expect(capabilities.unsupported[key] == nil, "\(key) is listed both partial and unsupported")
        }
    }

    @Test("Every claim carries a reason a person can act on")
    func reasonsAreSubstantive() {
        // "not supported" tells a user nothing. Each entry earned its
        // wording by explaining what the runtime lacks, or what to do
        // instead.
        for (key, reason) in capabilities.unsupported {
            #expect(reason.count > 20, "\(key)'s reason is too thin to act on: '\(reason)'")
            #expect(reason.lowercased() != "not supported", "\(key) has a placeholder reason")
        }
        for (key, info) in capabilities.partial {
            #expect(info.reason.count > 20, "\(key)'s reason is too thin to act on: '\(info.reason)'")
            #expect(!info.supported.isEmpty, "\(key) is partial but lists nothing it supports")
        }
    }

    @Test("Every flag is spelled as a flag")
    func flagsLookLikeFlags() {
        for flag in allFlags {
            #expect(flag.hasPrefix("-"), "'\(flag)' is not a flag")
        }
    }

    @Test("A key the manifest maps is reported as supported, and one it does not is not")
    func supportsReflectsTheMaps() {
        #expect(capabilities.supports("mem_limit"))
        #expect(!capabilities.supports("restart"))
        // `hostname` has no runtime equivalent: the container's hostname
        // is its name. It must not read as supported again.
        #expect(!capabilities.supports("hostname"))
    }
}
