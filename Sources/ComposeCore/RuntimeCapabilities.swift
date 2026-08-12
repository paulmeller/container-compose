//
//  RuntimeCapabilities.swift
//  container-compose
//

import Foundation

/// What a target runtime can actually express.
///
/// Existing tooling encodes this implicitly — a key is honored, warned about,
/// or silently dropped, and you find out which by running it. Modelling it as
/// data means a consumer can render "this won't work, and here's why" *before*
/// the user commits, and means retargeting a different runtime is a value
/// change rather than a rewrite.
public struct RuntimeCapabilities: Sendable, Codable, Hashable {

    /// Compose keys that take a list, mapped to the flag each element becomes.
    public var listFlags: [String: String]

    /// Compose keys that take a scalar, mapped to their flag.
    public var scalarFlags: [String: String]

    /// Compose keys that are booleans, mapped to the flag their `true` emits.
    public var booleanFlags: [String: String]

    /// Keys the runtime cannot express, and why. The reason is the runtime's
    /// limitation, never a restatement of the key name.
    public var unsupported: [String: String]

    /// Keys only partly honored: the reason, plus what *does* apply.
    public var partial: [String: (reason: String, supported: [String])]

    public init(
        listFlags: [String: String] = [:],
        scalarFlags: [String: String] = [:],
        booleanFlags: [String: String] = [:],
        unsupported: [String: String] = [:],
        partial: [String: (reason: String, supported: [String])] = [:]
    ) {
        self.listFlags = listFlags
        self.scalarFlags = scalarFlags
        self.booleanFlags = booleanFlags
        self.unsupported = unsupported
        self.partial = partial
    }

    /// The keys a service declares that this runtime cannot fully honor.
    public func unsupportedKeys(declaredIn raw: [String: Any]) -> [UnsupportedKey] {
        var found: [UnsupportedKey] = []

        for (key, reason) in unsupported where raw[key] != nil {
            found.append(UnsupportedKey(key: key, support: .none, reason: reason))
        }
        for (key, info) in partial where raw[key] != nil {
            found.append(UnsupportedKey(
                key: key,
                support: .partial,
                reason: info.reason,
                detail: "supported: \(info.supported.joined(separator: ", "))"
            ))
        }
        return found.sorted { $0.key < $1.key }
    }

    /// Whether a key is expressible at all.
    public func supports(_ key: String) -> Bool {
        listFlags[key] != nil || scalarFlags[key] != nil || booleanFlags[key] != nil
    }
}

// MARK: - Apple's container runtime

extension RuntimeCapabilities {
    /// Apple `container` 1.x.
    ///
    /// Every entry was verified against the runtime's own option list rather
    /// than assumed from Docker's surface — the two diverge sharply, and the
    /// gaps are the whole reason this type exists.
    public static let appleContainer = RuntimeCapabilities(
        listFlags: [
            "cap_add": "--cap-add",
            "cap_drop": "--cap-drop",
            "dns": "--dns",
            "dns_search": "--dns-search",
            "dns_opt": "--dns-option",
            "tmpfs": "--tmpfs",
        ],
        scalarFlags: [
            "user": "--user",
            "working_dir": "--cwd",
            "platform": "--platform",
            "shm_size": "--shm-size",
            "runtime": "--runtime",
            "mem_limit": "--memory",
            "hostname": "--name",
        ],
        booleanFlags: [
            "privileged": "--privileged",
            "read_only": "--read-only",
            "init": "--init",
            "stdin_open": "-i",
            "tty": "-t",
        ],
        unsupported: [
            "restart": "the runtime has no restart-policy flag; containers are never restarted automatically",
            "configs": "a Swarm feature with no mount equivalent; nothing is placed in the container",
            "secrets": "a Swarm feature with no mount equivalent; nothing appears at /run/secrets",
            "network_mode": "only named networks are supported; host/none/container: modes have no equivalent",
            "devices": "there is no device-passthrough flag",
            "device_cgroup_rules": "cgroup device rules are not exposed",
            "pid": "PID namespace sharing is not exposed",
            "ipc": "IPC namespace sharing is not exposed",
            "uts": "UTS namespace configuration is not exposed",
            "userns_mode": "user-namespace remapping is not exposed",
            "security_opt": "seccomp/apparmor/no-new-privileges are not exposed",
            "group_add": "supplementary groups are not exposed",
            "sysctls": "kernel parameters cannot be set per container",
            "cgroup_parent": "cgroup placement is not exposed",
            "blkio_config": "block-IO weighting and throttling are not exposed",
            "storage_opt": "per-container storage options are not exposed",
            "oom_kill_disable": "OOM-killer policy is not exposed",
            "oom_score_adj": "OOM score adjustment is not exposed",
            "mem_swappiness": "swap tuning is not exposed",
            "memswap_limit": "swap limits are not exposed",
            "mem_reservation": "soft reservations are not exposed; memory limits are hard only",
            "cpu_shares": "relative CPU weighting is not exposed; CPUs are allocated whole",
            "cpuset": "CPU pinning is not exposed",
            "links": "superseded by networks; service names already resolve",
            "external_links": "attach both containers to a shared network instead",
            "expose": "informational in Compose; it carries no runtime effect",
            "volumes_from": "declare the volume on each service instead",
            "scale": "the runtime has no replica concept",
            "stop_grace_period": "the stop timeout is not configurable",
            "stop_signal": "the stop signal is not configurable",
            "isolation": "a Windows concept with no equivalent",
            "gpus": "GPU passthrough is not available",
            "pull_policy": "not implemented; images are pulled when absent",
            "label_file": "declare labels inline under 'labels'",
            "annotations": "OCI annotations are not exposed",
        ],
        partial: [
            "deploy": (
                reason: "replicas, placement and update strategies are orchestrator concepts",
                supported: ["resources.limits.cpus", "resources.limits.memory"]
            ),
            "extra_hosts": (
                reason: "the runtime has no --add-host; entries are written into a generated /etc/hosts instead, which replaces the daemon's own file",
                supported: ["hostname:ip", "hostname:host-gateway"]
            ),
        ]
    )
}

// `partial` holds a tuple, which is not automatically Codable/Hashable.
// Encoded as a nested object so the manifest can cross the protocol boundary.
extension RuntimeCapabilities {
    private struct PartialEntry: Codable, Hashable {
        let reason: String
        let supported: [String]
    }

    private enum CodingKeys: String, CodingKey {
        case listFlags, scalarFlags, booleanFlags, unsupported, partial
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        listFlags = try container.decode([String: String].self, forKey: .listFlags)
        scalarFlags = try container.decode([String: String].self, forKey: .scalarFlags)
        booleanFlags = try container.decode([String: String].self, forKey: .booleanFlags)
        unsupported = try container.decode([String: String].self, forKey: .unsupported)
        let decodedPartial = try container.decode([String: PartialEntry].self, forKey: .partial)
        partial = decodedPartial.mapValues { ($0.reason, $0.supported) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(listFlags, forKey: .listFlags)
        try container.encode(scalarFlags, forKey: .scalarFlags)
        try container.encode(booleanFlags, forKey: .booleanFlags)
        try container.encode(unsupported, forKey: .unsupported)
        try container.encode(partial.mapValues { PartialEntry(reason: $0.reason, supported: $0.supported) }, forKey: .partial)
    }

    public static func == (lhs: RuntimeCapabilities, rhs: RuntimeCapabilities) -> Bool {
        lhs.listFlags == rhs.listFlags && lhs.scalarFlags == rhs.scalarFlags
            && lhs.booleanFlags == rhs.booleanFlags && lhs.unsupported == rhs.unsupported
            && lhs.partial.mapValues({ [$0.reason] + $0.supported }) == rhs.partial.mapValues({ [$0.reason] + $0.supported })
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(listFlags)
        hasher.combine(scalarFlags)
        hasher.combine(booleanFlags)
        hasher.combine(unsupported)
    }
}
