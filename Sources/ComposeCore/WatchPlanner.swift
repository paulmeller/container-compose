//
//  WatchPlanner.swift
//  container-compose
//

import Foundation

/// What kind of change a path underwent between two snapshots.
public enum WatchChangeKind: String, Sendable, Equatable {
    case added
    case modified
    case removed
}

/// One changed path, as decided by `WatchPlanner.diff`.
public struct WatchChange: Sendable, Equatable {
    public let path: String
    public let kind: WatchChangeKind

    public init(path: String, kind: WatchChangeKind) {
        self.path = path
        self.kind = kind
    }
}

/// The decision logic behind `watch`, kept pure and separate from the
/// filesystem polling that produces its inputs — mirroring `Reconciler`:
/// given two snapshots (host path -> an opaque signature string, e.g. a
/// modification time), what changed is a mathematical function of the two,
/// testable without touching a real filesystem.
public enum WatchPlanner {

    /// Compares two path -> signature snapshots. A path present in `current`
    /// but not `previous` is `.added`; present in both with a different
    /// signature is `.modified`; present in `previous` but not `current` is
    /// `.removed`.
    public static func diff(previous: [String: String], current: [String: String]) -> [WatchChange] {
        var changes: [WatchChange] = []
        for (path, signature) in current {
            if let previousSignature = previous[path] {
                if previousSignature != signature {
                    changes.append(WatchChange(path: path, kind: .modified))
                }
            } else {
                changes.append(WatchChange(path: path, kind: .added))
            }
        }
        for path in previous.keys where current[path] == nil {
            changes.append(WatchChange(path: path, kind: .removed))
        }
        return changes.sorted { $0.path < $1.path }
    }

    /// Whether `rule.ignore` excludes `path` — a substring match, matching
    /// what `WatchRule.ignore` documents ("substrings to ignore within
    /// `path`"), not a glob.
    public static func isIgnored(_ path: String, by rule: WatchRule) -> Bool {
        guard let ignore = rule.ignore else { return false }
        return ignore.contains { path.contains($0) }
    }

    /// Strips `.` path components from a `develop.watch` rule's `path`
    /// (typically written `./src`-style in a compose file) before it is ever
    /// handed to `Foundation.URL.appendingPathComponent`, which does NOT
    /// collapse a literal `./` the way a real directory walk normalizes the
    /// paths it hands back.
    ///
    /// Left uncollapsed, `./src` and the paths a filesystem enumerator
    /// reports for files under it stop agreeing character-for-character —
    /// exactly what silently truncated synced filenames during live testing
    /// (`./src` turned `greeting.txt` into `reeting.txt`, since the caller's
    /// prefix-stripping arithmetic dropped two too many characters).
    /// `.standardizedFileURL` was considered and rejected: on macOS it
    /// resolves `/tmp` to `/private/tmp` (a symlink), which would reintroduce
    /// the identical class of mismatch for any watched path under one.
    public static func normalizedRulePath(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
}
