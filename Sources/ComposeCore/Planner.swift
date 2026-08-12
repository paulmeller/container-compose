//
//  Planner.swift
//  container-compose
//

import Foundation
import Yams

/// Inputs to planning. Everything ambient is passed in explicitly so the same
/// inputs always yield the same `Plan`.
public struct PlanOptions: Sendable {
    /// Project name; namespaces containers, volumes and networks.
    public var projectName: String

    /// Directory the compose document lives in. Relative paths inside it
    /// (`extends: {file:}`, `env_file:`, build contexts) resolve against this.
    public var directory: String

    /// Variables available to `${...}` interpolation. Typically the process
    /// environment merged over the project `.env`. Passed in rather than read,
    /// so planning is reproducible.
    public var variables: [String: String]

    /// Active Compose profiles.
    public var activeProfiles: Set<String>

    /// Services explicitly requested; empty means the default selection.
    public var requestedServices: [String]

    /// What the target runtime can express. Drives the `unsupported` list on
    /// each planned service.
    public var capabilities: RuntimeCapabilities

    public init(
        projectName: String,
        directory: String = ".",
        variables: [String: String] = [:],
        activeProfiles: Set<String> = [],
        requestedServices: [String] = [],
        capabilities: RuntimeCapabilities = .appleContainer
    ) {
        self.projectName = projectName
        self.directory = directory
        self.variables = variables
        self.activeProfiles = activeProfiles
        self.requestedServices = requestedServices
        self.capabilities = capabilities
    }
}

public enum PlanError: Error, Equatable, Sendable {
    case malformedDocument(String)
    case noSuchService(String)
    case serviceMissingImageAndBuild(String)
    case dependencyCycle([String])
    case extendsCycle([String])
    case extendsTargetMissing(service: String, target: String, file: String?)
    case extendsFileMissing(service: String, file: String)
    case requiredVariableUnset(variable: String, message: String)
}

/// Turns a compose document into a `Plan`.
///
/// The whole layer is a pure function of (document, options, file provider):
/// no printing, no runtime calls, no clock, no ambient environment. That is
/// what lets the hard parts — interpolation, inheritance, ordering — be tested
/// exhaustively without a container daemon anywhere in sight.
public struct Planner: Sendable {
    private let files: ComposeFileProvider

    public init(files: ComposeFileProvider = FileSystemProvider()) {
        self.files = files
    }

    public func plan(document: String, options: PlanOptions) throws -> Plan {
        // 1. Parse, and resolve `extends` while still working with raw YAML, so
        //    everything downstream sees fully-merged services.
        guard let root = (try? Yams.load(yaml: document)) as? [String: Any] else {
            throw PlanError.malformedDocument("document is not a YAML mapping")
        }
        guard let rawServices = root["services"] as? [String: Any] else {
            throw PlanError.malformedDocument("no 'services' section")
        }

        var merged: [String: [String: Any]] = [:]
        var extendsCache: [String: [String: Any]] = [:]
        for name in rawServices.keys {
            merged[name] = try ExtendsResolver(files: files).resolve(
                service: name,
                in: rawServices,
                directory: options.directory,
                cache: &extendsCache,
                chain: []
            )
        }

        // 2. Validate requested names before any further work, so a typo fails
        //    immediately rather than planning an empty project.
        for requested in options.requestedServices where merged[requested] == nil {
            throw PlanError.noSuchService(requested)
        }

        // 3. Profile gating and dependency expansion decide the selection.
        let selected = try select(from: merged, options: options)

        // 4. Resolve each selected service into a value.
        var planned: [PlannedService] = []
        for name in selected.sorted() {
            planned.append(try resolveService(name: name, raw: merged[name] ?? [:], options: options))
        }

        // 5. Order, and group into concurrently-startable waves.
        let waves = try Self.dependencyWaves(planned)
        let ordered = waves.flatMap { wave in
            wave.compactMap { name in planned.first { $0.name == name } }
        }

        return Plan(
            projectName: options.projectName,
            services: ordered,
            waves: waves,
            volumes: resolveVolumes(root, options: options),
            networks: resolveNetworks(root, options: options)
        )
    }

    // MARK: - Selection

    /// Services to act on: the profile-eligible set (or the explicitly
    /// requested one), plus everything they transitively depend on.
    ///
    /// Dependencies bypass the profile gate, per the Compose spec — a service
    /// you asked for cannot be started without them.
    private func select(from services: [String: [String: Any]], options: PlanOptions) throws -> Set<String> {
        var roots: [String] = []
        if options.requestedServices.isEmpty {
            for (name, raw) in services {
                let profiles = (raw["profiles"] as? [Any])?.map { "\($0)" } ?? []
                if profiles.isEmpty || !options.activeProfiles.isDisjoint(with: Set(profiles)) {
                    roots.append(name)
                }
            }
        } else {
            roots = options.requestedServices
        }

        var selected = Set<String>()
        var queue = roots
        while let name = queue.popLast() {
            guard services[name] != nil, selected.insert(name).inserted else { continue }
            for dependency in Self.dependsOn(services[name] ?? [:]) where services[dependency.service] != nil {
                queue.append(dependency.service)
            }
        }
        return selected
    }

    // MARK: - Service resolution

    private func resolveService(name: String, raw: [String: Any], options: PlanOptions) throws -> PlannedService {
        var variables = options.variables

        // `env_file` contributes variables to the service's own environment,
        // beneath anything the service declares inline.
        var fileEnvironment: [String: String] = [:]
        for path in stringList(raw["env_file"]) {
            let resolved = try Interpolation.resolve(path, variables: variables)
            let full = absolute(resolved, relativeTo: options.directory)
            if let contents = files.contents(atPath: full) {
                fileEnvironment.merge(Self.parseEnvFile(contents)) { _, new in new }
            }
        }
        variables.merge(fileEnvironment) { current, _ in current }

        func interpolate(_ value: String) throws -> String {
            do {
                return try Interpolation.resolve(value, variables: variables)
            } catch let failure as Interpolation.Failure {
                switch failure {
                case .required(let variable, let message):
                    throw PlanError.requiredVariableUnset(variable: variable, message: message)
                }
            }
        }

        let image = try (raw["image"] as? String).map(interpolate)
        let build = try resolveBuild(raw["build"], interpolate: interpolate)
        guard image != nil || build != nil else {
            throw PlanError.serviceMissingImageAndBuild(name)
        }

        // Service-declared environment resolves against the file-derived set,
        // then wins over it.
        var environment = fileEnvironment
        for (key, value) in Self.mapping(raw["environment"]) {
            environment[try interpolate(key)] = try interpolate(value)
        }

        var labels = try Self.mapping(raw["labels"]).reduce(into: [String: String]()) { acc, pair in
            acc[try interpolate(pair.key)] = try interpolate(pair.value)
        }
        // Stamped last so they cannot be overridden: these are how every other
        // layer finds this project's containers.
        labels["com.docker.compose.project"] = options.projectName
        labels["com.docker.compose.service"] = name

        let service = PlannedService(
            name: name,
            image: image,
            build: build,
            command: try stringList(raw["command"], allowScalar: true).map(interpolate),
            entrypoint: try stringList(raw["entrypoint"], allowScalar: true).map(interpolate),
            environment: environment,
            ports: try stringList(raw["ports"]).map(interpolate),
            volumes: try stringList(raw["volumes"]).map(interpolate),
            networks: try stringList(raw["networks"]).map(interpolate),
            labels: labels,
            dependsOn: Self.dependsOn(raw),
            healthcheck: Self.healthcheck(raw["healthcheck"]),
            profiles: stringList(raw["profiles"]),
            runtimeOptions: try runtimeOptions(raw, capabilities: options.capabilities, interpolate: interpolate),
            unsupported: options.capabilities.unsupportedKeys(declaredIn: raw),
            configHash: ""
        )

        // Hash last, over the resolved value, so it captures exactly what will
        // run — including interpolated values, which is the whole point.
        return service.withConfigHash(Self.hash(service))
    }

    private func resolveBuild(_ value: Any?, interpolate: (String) throws -> String) rethrows -> PlannedBuild? {
        if let context = value as? String {
            return PlannedBuild(context: try interpolate(context), dockerfile: nil, args: [:], target: nil)
        }
        guard let mapping = value as? [String: Any] else { return nil }
        let context = (mapping["context"] as? String) ?? "."
        var args: [String: String] = [:]
        for (key, argument) in Self.mapping(mapping["args"]) {
            args[key] = try interpolate(argument)
        }
        return PlannedBuild(
            context: try interpolate(context),
            dockerfile: try (mapping["dockerfile"] as? String).map(interpolate),
            args: args,
            target: mapping["target"] as? String
        )
    }

    /// Maps compose keys onto the runtime flags this runtime actually exposes.
    private func runtimeOptions(
        _ raw: [String: Any],
        capabilities: RuntimeCapabilities,
        interpolate: (String) throws -> String
    ) rethrows -> [RuntimeOption] {
        var options: [RuntimeOption] = []

        for (key, flag) in capabilities.listFlags {
            for value in stringList(raw[key], allowScalar: true) {
                options.append(RuntimeOption(flag: flag, value: try interpolate(value)))
            }
        }
        for (key, flag) in capabilities.scalarFlags {
            if let value = raw[key] as? String {
                options.append(RuntimeOption(flag: flag, value: try interpolate(value)))
            } else if let number = raw[key] as? Int {
                options.append(RuntimeOption(flag: flag, value: "\(number)"))
            }
        }
        for (key, flag) in capabilities.booleanFlags {
            if raw[key] as? Bool == true {
                options.append(RuntimeOption(flag: flag))
            }
        }

        // `ulimits` has two spellings; both normalize to type=soft[:hard].
        if let simple = raw["ulimits"] as? [String: Int] {
            for (name, value) in simple.sorted(by: { $0.key < $1.key }) {
                options.append(RuntimeOption(flag: "--ulimit", value: "\(name)=\(value)"))
            }
        } else if let detailed = raw["ulimits"] as? [String: [String: Int]] {
            for (name, limits) in detailed.sorted(by: { $0.key < $1.key }) {
                guard let soft = limits["soft"] else { continue }
                let value = limits["hard"].map { "\(name)=\(soft):\($0)" } ?? "\(name)=\(soft)"
                options.append(RuntimeOption(flag: "--ulimit", value: value))
            }
        }

        return options.sorted { ($0.flag, $0.value ?? "") < ($1.flag, $1.value ?? "") }
    }

    // MARK: - Ordering

    /// Groups services into waves that can each start concurrently.
    ///
    /// Dependencies outside the selection are ignored rather than deferring a
    /// service forever — selection has already guaranteed the set is closed.
    static func dependencyWaves(_ services: [PlannedService]) throws -> [[String]] {
        let present = Set(services.map(\.name))
        var remaining = services
        var placed = Set<String>()
        var waves: [[String]] = []

        while !remaining.isEmpty {
            let ready = remaining.filter { service in
                service.dependsOn
                    .filter { present.contains($0.service) }
                    .allSatisfy { placed.contains($0.service) }
            }
            guard !ready.isEmpty else {
                throw PlanError.dependencyCycle(remaining.map(\.name).sorted())
            }
            waves.append(ready.map(\.name).sorted())
            placed.formUnion(ready.map(\.name))
            let readyNames = Set(ready.map(\.name))
            remaining.removeAll { readyNames.contains($0.name) }
        }
        return waves
    }

    // MARK: - Project resources

    private func resolveVolumes(_ root: [String: Any], options: PlanOptions) -> [PlannedVolume] {
        guard let declared = root["volumes"] as? [String: Any] else { return [] }
        return declared.keys.sorted().map { name in
            let config = declared[name] as? [String: Any]
            let external = (config?["external"] as? Bool) == true
            let explicit = config?["name"] as? String
            return PlannedVolume(
                name: name,
                resolvedName: explicit ?? (external ? name : "\(options.projectName)_\(name)"),
                external: external
            )
        }
    }

    private func resolveNetworks(_ root: [String: Any], options: PlanOptions) -> [PlannedNetwork] {
        guard let declared = root["networks"] as? [String: Any] else { return [] }
        return declared.keys.sorted().map { name in
            let config = declared[name] as? [String: Any]
            let external = (config?["external"] as? Bool) == true
            let explicit = config?["name"] as? String
            return PlannedNetwork(
                name: name,
                resolvedName: explicit ?? (external ? name : "\(options.projectName)_\(name)"),
                external: external
            )
        }
    }

    // MARK: - Raw-value helpers

    private func stringList(_ value: Any?, allowScalar: Bool = false) -> [String] {
        if let list = value as? [Any] { return list.map { "\($0)" } }
        if allowScalar, let scalar = value as? String { return [scalar] }
        if !allowScalar, let scalar = value as? String { return [scalar] }
        return []
    }

    private func absolute(_ path: String, relativeTo directory: String) -> String {
        path.hasPrefix("/") ? path : URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: directory)).standardizedFileURL.path
    }

    static func mapping(_ value: Any?) -> [String: String] {
        if let map = value as? [String: Any] {
            return map.reduce(into: [:]) { $0[$1.key] = "\($1.value)" }
        }
        // The `KEY=value` list form.
        if let list = value as? [Any] {
            return list.reduce(into: [:]) { result, entry in
                let text = "\(entry)"
                guard let separator = text.firstIndex(of: "=") else {
                    result[text] = ""
                    return
                }
                result[String(text[text.startIndex..<separator])] = String(text[text.index(after: separator)...])
            }
        }
        return [:]
    }

    static func dependsOn(_ raw: [String: Any]) -> [ServiceDependency] {
        // Short form: a list of names.
        if let list = raw["depends_on"] as? [Any] {
            return list.map { ServiceDependency(service: "\($0)") }.sorted { $0.service < $1.service }
        }
        // Long form: a mapping with per-dependency conditions.
        if let map = raw["depends_on"] as? [String: Any] {
            return map.keys.sorted().map { name in
                let condition = ((map[name] as? [String: Any])?["condition"] as? String)
                    .flatMap(ServiceDependency.Condition.init(rawValue:)) ?? .started
                return ServiceDependency(service: name, condition: condition)
            }
        }
        return []
    }

    static func healthcheck(_ value: Any?) -> PlannedHealthcheck? {
        guard let map = value as? [String: Any] else { return nil }
        if map["disable"] as? Bool == true {
            return PlannedHealthcheck(test: [], interval: nil, timeout: nil, retries: nil, startPeriod: nil, disabled: true)
        }
        var test: [String] = []
        if let list = map["test"] as? [Any] { test = list.map { "\($0)" } }
        if let scalar = map["test"] as? String { test = ["CMD-SHELL", scalar] }
        return PlannedHealthcheck(
            test: test,
            interval: duration(map["interval"]),
            timeout: duration(map["timeout"]),
            retries: map["retries"] as? Int,
            startPeriod: duration(map["start_period"]),
            disabled: false
        )
    }

    /// Parses Compose durations (`30s`, `1m30s`, `500ms`) into seconds.
    static func duration(_ value: Any?) -> Double? {
        guard let text = value as? String else {
            if let number = value as? Int { return Double(number) }
            if let number = value as? Double { return number }
            return nil
        }
        var total = 0.0
        var number = ""
        var unit = ""
        for character in text {
            if character.isNumber || character == "." {
                if !unit.isEmpty {
                    total += Self.seconds(number, unit)
                    number = ""
                    unit = ""
                }
                number.append(character)
            } else {
                unit.append(character)
            }
        }
        total += Self.seconds(number, unit)
        return total == 0 && text != "0" ? nil : total
    }

    private static func seconds(_ number: String, _ unit: String) -> Double {
        guard let value = Double(number) else { return 0 }
        switch unit {
        case "ms": return value / 1000
        case "s", "": return value
        case "m": return value * 60
        case "h": return value * 3600
        default: return value
        }
    }

    /// Parses `.env`-file syntax (`KEY=value`, `#` comments, blank lines,
    /// matching surrounding quotes stripped as delimiters). Public: the
    /// project-level `.env` a consumer loads before calling `plan` uses
    /// exactly the same syntax as a service's `env_file:`, and duplicating
    /// this parser at the call site would be the same logic maintained twice.
    public static func parseEnvFile(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            // Strip matching surrounding quotes, which are delimiters rather
            // than part of the value.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }

    /// Stable across processes and runs: `Hasher` is seeded per-process, so it
    /// cannot be used for a value that gets stamped on a container and compared
    /// by a later invocation.
    static func hash(_ service: PlannedService) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(service) else { return "" }
        return Self.fnv1a(data)
    }

    private static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return String(hash, radix: 16)
    }
}

extension PlannedService {
    /// Returns a copy carrying `hash`. The hash is computed over the service
    /// with an empty hash field, so it is reproducible.
    func withConfigHash(_ hash: String) -> PlannedService {
        PlannedService(
            name: name, image: image, build: build, command: command, entrypoint: entrypoint,
            environment: environment, ports: ports, volumes: volumes, networks: networks,
            labels: labels, dependsOn: dependsOn, healthcheck: healthcheck, profiles: profiles,
            runtimeOptions: runtimeOptions, unsupported: unsupported, configHash: hash
        )
    }
}
