//
//  ComposeFileMerge.swift
//  container-compose
//
//  `docker compose -f base.yml -f override.yml` merges the files before
//  planning anything. That is what lets a template stay pristine while a
//  local file adjusts it — the case this exists for is an app installed
//  from a catalog, where the template is refetched on every reinstall and
//  would otherwise take local edits with it.
//
//  Merging happens on the parsed documents and produces one document
//  string, so everything downstream — extends resolution, magic-variable
//  checking, planning — sees a single fully-merged file and needs no
//  knowledge that more than one existed.
//

import Foundation
import Yams

public enum ComposeFileMerge {
    /// Top-level sections that are keyed collections: merged per entry,
    /// rather than the later file's section replacing the earlier one
    /// wholesale. A file that adds one volume must not delete the rest.
    private static let keyedSections: Set<String> = ["services", "volumes", "networks", "configs", "secrets"]

    public enum MergeError: Error, CustomStringConvertible {
        case notAMapping(index: Int)

        public var description: String {
            switch self {
            case .notAMapping(let index):
                return "compose file \(index + 1) is not a YAML mapping"
            }
        }
    }

    /// Merge in order: each document overrides the ones before it.
    ///
    /// A single document is returned untouched rather than round-tripped
    /// through the parser. The round trip is semantically faithful but not
    /// textually, and the overwhelmingly common case should not pay for a
    /// feature it is not using — nor risk it.
    public static func merge(documents: [String]) throws -> String {
        guard documents.count > 1 else { return documents.first ?? "" }

        var accumulated: [String: Any] = [:]
        for (index, document) in documents.enumerated() {
            // An empty override file is legitimate — the app writes one
            // before the user has adjusted anything.
            if document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let root = (try? Yams.load(yaml: document)) as? [String: Any] else {
                throw MergeError.notAMapping(index: index)
            }
            accumulated = mergeDocument(override: root, onto: accumulated)
        }
        return try Yams.dump(object: accumulated)
    }

    static func mergeDocument(override: [String: Any], onto base: [String: Any]) -> [String: Any] {
        var result = base
        for (key, overrideValue) in override {
            guard let baseValue = result[key] else {
                result[key] = overrideValue
                continue
            }
            guard keyedSections.contains(key),
                  let baseSection = baseValue as? [String: Any],
                  let overrideSection = overrideValue as? [String: Any]
            else {
                result[key] = overrideValue
                continue
            }
            result[key] = mergeSection(override: overrideSection, onto: baseSection, isService: key == "services")
        }
        return result
    }

    private static func mergeSection(
        override: [String: Any],
        onto base: [String: Any],
        isService: Bool
    ) -> [String: Any] {
        var result = base
        for (name, overrideEntry) in override {
            guard let baseEntry = result[name] as? [String: Any],
                  let overrideMap = overrideEntry as? [String: Any]
            else {
                result[name] = overrideEntry
                continue
            }
            // Services reuse the same key-by-key rules `extends` uses:
            // ports and the other multi-value options concatenate,
            // environment and labels merge entry-by-entry, everything else
            // takes the later value. Keeping one implementation means an
            // override file and an `extends` cannot disagree about what
            // merging means.
            result[name] = isService
                ? ExtendsResolver.merge(local: overrideMap, onto: baseEntry)
                : overrideMap.merging(baseEntry) { later, _ in later }
        }
        return result
    }
}
