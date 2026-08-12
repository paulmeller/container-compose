//
//  ExtendsResolver.swift
//  container-compose
//

import Foundation
import Yams

/// Resolves the Compose `extends` key on raw YAML, before decoding.
///
/// Doing it here rather than in the model means nothing downstream — planning,
/// hashing, execution — has to know inheritance exists. By the time a service
/// is planned it is already a single merged definition.
struct ExtendsResolver {
    let files: ComposeFileProvider

    /// - Parameters:
    ///   - chain: Ancestors currently being resolved, keyed by file+service, so
    ///     a cycle is reported instead of recursing forever.
    func resolve(
        service name: String,
        in services: [String: Any],
        directory: String,
        cache: inout [String: [String: Any]],
        chain: [String]
    ) throws -> [String: Any] {
        guard var raw = services[name] as? [String: Any] else { return [:] }
        guard let extends = raw["extends"] else { return raw }

        let key = "\(directory)#\(name)"
        if let cached = cache[key] { return cached }
        if chain.contains(key) {
            throw PlanError.extendsCycle(chain.map { $0.components(separatedBy: "#").last ?? $0 } + [name])
        }

        let target: String
        let file: String?
        if let shorthand = extends as? String {
            target = shorthand
            file = nil
        } else if let mapping = extends as? [String: Any], let service = mapping["service"] as? String {
            target = service
            file = mapping["file"] as? String
        } else {
            throw PlanError.extendsTargetMissing(service: name, target: "", file: nil)
        }

        raw.removeValue(forKey: "extends")

        let base: [String: Any]
        if let file {
            let path = file.hasPrefix("/")
                ? file
                : URL(fileURLWithPath: file, relativeTo: URL(fileURLWithPath: directory)).standardizedFileURL.path
            guard let contents = files.contents(atPath: path) else {
                throw PlanError.extendsFileMissing(service: name, file: file)
            }
            guard
                let root = (try? Yams.load(yaml: contents)) as? [String: Any],
                let baseServices = root["services"] as? [String: Any],
                baseServices[target] != nil
            else {
                throw PlanError.extendsTargetMissing(service: name, target: target, file: file)
            }
            // The referenced document may itself use `extends`, resolved
            // relative to *its own* directory.
            var nested: [String: [String: Any]] = [:]
            base = try resolve(
                service: target,
                in: baseServices,
                directory: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                cache: &nested,
                chain: chain + [key]
            )
        } else {
            guard services[target] != nil else {
                throw PlanError.extendsTargetMissing(service: name, target: target, file: nil)
            }
            base = try resolve(service: target, in: services, directory: directory, cache: &cache, chain: chain + [key])
        }

        let merged = Self.merge(local: raw, onto: base)
        cache[key] = merged
        return merged
    }

    /// Keys whose values concatenate rather than replace, per the spec's
    /// "multi-value options".
    ///
    /// `volumes` is deliberately absent: two mounts at one container path
    /// conflict, so inheriting both would produce a container that cannot
    /// express what either file asked for. Local replacement is the safer read.
    private static let concatenated: Set<String> = [
        "ports", "expose", "dns", "dns_search", "dns_opt", "tmpfs",
        "cap_add", "cap_drop", "depends_on", "external_links", "links",
        "env_file", "profiles", "secrets", "configs",
    ]

    /// Keys merged entry-by-entry, local winning per entry.
    private static let mergedMappings: Set<String> = [
        "environment", "labels", "ulimits", "extra_hosts", "deploy", "build",
    ]

    static func merge(local: [String: Any], onto base: [String: Any]) -> [String: Any] {
        var result = base

        for (key, localValue) in local {
            guard let baseValue = result[key] else {
                result[key] = localValue
                continue
            }

            if concatenated.contains(key), let baseList = baseValue as? [Any], let localList = localValue as? [Any] {
                var seen = Set<String>()
                result[key] = (baseList + localList).filter { seen.insert("\($0)").inserted }
                continue
            }

            if mergedMappings.contains(key), let baseMap = baseValue as? [String: Any], let localMap = localValue as? [String: Any] {
                result[key] = merge(local: localMap, onto: baseMap)
                continue
            }

            result[key] = localValue
        }

        return result
    }
}
