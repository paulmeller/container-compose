//
//  Develop.swift
//  container-compose
//

import Foundation

/// What `watch` should do when a watched path changes.
public enum WatchAction: String, Codable, Sendable {
    /// Copy the changed file into the running container.
    case sync
    /// Rebuild the service's image and recreate the container.
    case rebuild
    /// Copy the change in, then restart the container so it re-reads it.
    case syncRestart = "sync+restart"
}

/// One `develop.watch` rule.
public struct WatchRule: Codable, Hashable, Sendable {
    /// Host path to watch, relative to the compose file's directory.
    public let path: String

    /// What to do when something under `path` changes, as the raw string from
    /// the compose file — kept alongside `watchAction` (below) so an action
    /// this tool does not implement is reported rather than silently dropped.
    public let action: String

    /// Destination inside the container. Required by `sync` and
    /// `sync+restart`; meaningless for `rebuild`.
    public let target: String?

    /// Substrings to ignore within `path`, e.g. `node_modules`.
    public let ignore: [String]?

    public init(path: String, action: String, target: String? = nil, ignore: [String]? = nil) {
        self.path = path
        self.action = action
        self.target = target
        self.ignore = ignore
    }

    /// The parsed action, or nil when the file names one this tool does not
    /// recognize.
    public var watchAction: WatchAction? { WatchAction(rawValue: action) }
}

/// The Compose `develop` key: the inner-loop configuration `watch` acts on.
public struct Develop: Codable, Hashable, Sendable {
    public let watch: [WatchRule]?

    public init(watch: [WatchRule]? = nil) {
        self.watch = watch
    }
}
