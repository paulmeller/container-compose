//
//  ProtocolRequest.swift
//  container-compose
//

import Foundation

/// A parsed protocol invocation — the input side of the contract, mirroring
/// `ProtocolMessage` on the output side.
public struct ProtocolRequest: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        case up(services: [String])
        /// `volumes` is deliberately not implied by `remove`: containers and
        /// networks are cheap to rebuild, a volume is the data itself.
        case down(remove: Bool, volumes: Bool)
        case capabilities
        /// Prints this build's version.
        ///
        /// Exists so a consumer can establish, once and cheaply, that the
        /// binary on PATH is new enough for what it intends to call.
        /// Without it the only way to find out was to invoke a subcommand
        /// and read the failure — a stale build reports `unknown command`
        /// with the same exit code as a usage error, so each feature had
        /// to discover the problem separately.
        case version
        /// Resolves a Coolify service template's generated `SERVICE_*`
        /// variables into a plain env file, leaving the compose document
        /// untouched. `force` regenerates values that already exist.
        case translate(force: Bool)
        case build(services: [String])
        case pull(services: [String])
        case push(services: [String])
        case ps(all: Bool)
        case ls(all: Bool)
        case images
        case config
        case logs(services: [String], follow: Bool, tail: Int?)
        case start(services: [String])
        case stop(services: [String])
        case restart(services: [String])
        case kill(services: [String], signal: String)
        case rm(services: [String], force: Bool)
        case wait(services: [String], timeoutSeconds: Double?)
        case top(services: [String])
        case stats(services: [String])
        case port(service: String, containerPort: Int)
        case cp(source: String, destination: String)
        case export(service: String, outputPath: String)
        case exec(service: String, command: [String], tty: Bool)
        case run(service: String, command: [String], remove: Bool, tty: Bool)
        case watch(services: [String])
    }

    public var command: Command
    /// Required for every command that plans a project (everything except
    /// `capabilities`, `ls`, and lifecycle commands given an explicit
    /// `--project`); unused otherwise.
    public var composeFilePath: String?
    /// Explicit project name; when nil, derived from the compose file's
    /// containing directory — the same convention Compose itself uses.
    public var projectName: String?
    public var envFilePath: String?
    public var profiles: Set<String>

    public init(
        command: Command,
        composeFilePath: String? = nil,
        projectName: String? = nil,
        envFilePath: String? = nil,
        profiles: Set<String> = []
    ) {
        self.command = command
        self.composeFilePath = composeFilePath
        self.projectName = projectName
        self.envFilePath = envFilePath
        self.profiles = profiles
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case noCommand
        case unknownCommand(String)
        case missingValue(forFlag: String)
        case unknownFlag(String)
        case missingRequiredFlag(command: String, flag: String)
        case missingArgument(command: String, name: String)
        case invalidArgument(command: String, name: String, value: String)

        public var description: String {
            switch self {
            case .noCommand:
                return "no command given"
            case .unknownCommand(let name):
                return "unknown command '\(name)'"
            case .missingValue(let flag):
                return "'\(flag)' requires a value"
            case .unknownFlag(let flag):
                return "unknown flag '\(flag)'"
            case .missingRequiredFlag(let command, let flag):
                return "'\(command)' requires \(flag)"
            case .missingArgument(let command, let name):
                return "'\(command)' requires a \(name) argument"
            case .invalidArgument(let command, let name, let value):
                return "'\(command)': invalid \(name) '\(value)'"
            }
        }
    }

    /// How `container-compose` should render its output — human-readable
    /// text (the default, for a terminal) or one NDJSON `ProtocolMessage`
    /// per line (for a non-Swift consumer like Port Authority spawning this
    /// same binary). Never auto-detected from `isatty`: a script piping to
    /// `jq` must get the same output whether run interactively or in CI, so
    /// the format is only ever what `--format` explicitly says.
    public enum OutputFormat: String, Sendable {
        case text
        case ndjson
    }

    /// Extracts a global `--format text|ndjson` from `arguments`, wherever
    /// it appears, returning the requested format (`.text` if absent) and
    /// the remaining argv for `parse`.
    ///
    /// Deliberately a separate pass, not a case inside `parse`'s per-command
    /// switch: which renderer to use is a property of how the CLI presents
    /// a result, orthogonal to what operation `parse` resolves — every
    /// command accepts `--format` uniformly this way, rather than each of
    /// `parse`'s ~25 command cases needing to know about a flag that means
    /// nothing to the operation itself.
    public static func extractFormat(_ arguments: [String]) throws -> (format: OutputFormat, remaining: [String]) {
        var format: OutputFormat = .text
        var remaining: [String] = []
        var rest = arguments
        while !rest.isEmpty {
            let token = rest.removeFirst()
            guard token == "--format" else {
                remaining.append(token)
                continue
            }
            guard !rest.isEmpty else { throw ParseError.missingValue(forFlag: "--format") }
            let value = rest.removeFirst()
            guard let parsed = OutputFormat(rawValue: value) else {
                throw ParseError.invalidArgument(command: arguments.first ?? "", name: "--format", value: value)
            }
            format = parsed
        }
        return (format, remaining)
    }

    /// Parses argv (excluding the executable name at index 0).
    ///
    /// Hand-rolled rather than a dependency: the surface is fixed and this is
    /// exactly the kind of decision-of-substance that belongs in this
    /// library, testable without spawning a process — not in `main.swift`.
    /// Structured as one flag-consuming loop (every flag the whole command
    /// set uses, order-independent) that also collects bare tokens as
    /// `positionals`, followed by a per-command dispatch that interprets
    /// those positionals according to that command's own argument shape
    /// (service names for most commands; source/destination for `cp`;
    /// service+port for `port`; service+command for `exec`/`run`).
    public static func parse(_ arguments: [String]) throws -> ProtocolRequest {
        guard let commandName = arguments.first else { throw ParseError.noCommand }
        let rest = Array(arguments.dropFirst())

        // `exec`/`run` take an arbitrary inner command that this parser must
        // never look inside — a token like `-c` (`sh -c '...'`) is not one of
        // OUR flags, but the shared loop below cannot tell the difference. So
        // these two commands are parsed by an entirely separate path that
        // stops interpreting flags the moment it finds the service name, and
        // hands back everything after it completely untouched.
        if commandName == "exec" || commandName == "run" {
            return try parseExecOrRun(commandName, rest)
        }

        return try parseRemaining(commandName, rest)
    }

    private static func parseExecOrRun(_ commandName: String, _ arguments: [String]) throws -> ProtocolRequest {
        var rest = arguments
        var composeFilePath: String?
        var projectName: String?
        var envFilePath: String?
        var profiles: Set<String> = []
        var remove = false
        var noTTY = false
        var service: String?

        func takeValue(_ flag: String) throws -> String {
            guard !rest.isEmpty else { throw ParseError.missingValue(forFlag: flag) }
            return rest.removeFirst()
        }

        while !rest.isEmpty {
            let token = rest.removeFirst()
            switch token {
            case "--file", "-f":
                composeFilePath = try takeValue(token)
            case "--project", "-p":
                projectName = try takeValue(token)
            case "--env-file":
                envFilePath = try takeValue(token)
            case "--profile":
                profiles.insert(try takeValue(token))
            case "--remove":
                remove = true
            case "--no-tty", "-T":
                noTTY = true
            default:
                if token.hasPrefix("-") { throw ParseError.unknownFlag(token) }
                service = token
            }
            // The moment a service name is captured, every remaining token —
            // however it looks — is the inner command, not ours to parse.
            if service != nil { break }
        }
        guard let service else { throw ParseError.missingArgument(command: commandName, name: "service") }
        // `docker compose exec SERVICE COMMAND...` needs no separator, but a
        // literal `--` right after the service name is a common, harmless
        // habit (borrowed from tools that DO require one) — drop exactly one
        // if present, rather than leaking it through as the command's first
        // argument.
        if rest.first == "--" { rest.removeFirst() }
        let command = rest

        let base = ProtocolRequest(
            command: .capabilities,
            composeFilePath: composeFilePath,
            projectName: projectName,
            envFilePath: envFilePath,
            profiles: profiles
        )

        if commandName == "exec" {
            return base.with(.exec(service: service, command: command, tty: !noTTY))
        }
        guard composeFilePath != nil else { throw ParseError.missingRequiredFlag(command: commandName, flag: "--file") }
        // Matches `docker compose run`: the container is NOT removed after it
        // exits unless `--remove` (its `--rm`) is given — the opposite
        // default from `up`/`down`'s own container lifecycle, since a one-off
        // `run` container is often inspected afterward.
        return base.with(.run(service: service, command: command, remove: remove, tty: !noTTY))
    }

    private static func parseRemaining(_ commandName: String, _ arguments: [String]) throws -> ProtocolRequest {
        var rest = arguments

        var composeFilePath: String?
        var projectName: String?
        var envFilePath: String?
        var profiles: Set<String> = []
        var positionals: [String] = []
        var remove = false
        var force = false
        var follow = false
        var all = false
        var tail: Int?
        var signal = "KILL"
        var timeoutSeconds: Double?
        var outputPath: String?
        var volumes = false

        func takeValue(_ flag: String) throws -> String {
            guard !rest.isEmpty else { throw ParseError.missingValue(forFlag: flag) }
            return rest.removeFirst()
        }

        while !rest.isEmpty {
            let token = rest.removeFirst()
            switch token {
            case "--file", "-f":
                composeFilePath = try takeValue(token)
            case "--project", "-p":
                projectName = try takeValue(token)
            case "--env-file":
                envFilePath = try takeValue(token)
            case "--profile":
                profiles.insert(try takeValue(token))
            case "--remove":
                remove = true
            case "--volumes", "-v":
                volumes = true
            case "--force":
                force = true
            case "--follow":
                follow = true
            case "--all":
                all = true
            case "--tail":
                let value = try takeValue(token)
                guard let parsed = Int(value) else { throw ParseError.invalidArgument(command: commandName, name: "--tail", value: value) }
                tail = parsed
            case "--signal":
                signal = try takeValue(token)
            case "--timeout":
                let value = try takeValue(token)
                guard let parsed = Double(value) else { throw ParseError.invalidArgument(command: commandName, name: "--timeout", value: value) }
                timeoutSeconds = parsed
            case "--output", "-o":
                outputPath = try takeValue(token)
            default:
                if token.hasPrefix("-") {
                    throw ParseError.unknownFlag(token)
                }
                positionals.append(token)
            }
        }

        func requireFile() throws {
            guard composeFilePath != nil else { throw ParseError.missingRequiredFlag(command: commandName, flag: "--file") }
        }

        let base = ProtocolRequest(
            command: .capabilities,
            composeFilePath: composeFilePath,
            projectName: projectName,
            envFilePath: envFilePath,
            profiles: profiles
        )

        switch commandName {
        case "capabilities":
            return base.with(.capabilities)
        case "version", "--version":
            return base.with(.version)
        case "translate":
            try requireFile()
            return base.with(.translate(force: force))
        case "up":
            try requireFile()
            return base.with(.up(services: positionals))
        case "down":
            try requireFile()
            return base.with(.down(remove: remove, volumes: volumes))
        case "build":
            try requireFile()
            return base.with(.build(services: positionals))
        case "pull":
            try requireFile()
            return base.with(.pull(services: positionals))
        case "push":
            try requireFile()
            return base.with(.push(services: positionals))
        case "ps":
            // Only needs project resolution (--project or --file), not a full
            // plan — matches `down`.
            return base.with(.ps(all: all))
        case "ls":
            return base.with(.ls(all: all))
        case "images":
            return base.with(.images)
        case "config":
            try requireFile()
            return base.with(.config)
        case "logs":
            return base.with(.logs(services: positionals, follow: follow, tail: tail))
        case "start":
            return base.with(.start(services: positionals))
        case "stop":
            return base.with(.stop(services: positionals))
        case "restart":
            return base.with(.restart(services: positionals))
        case "kill":
            return base.with(.kill(services: positionals, signal: signal))
        case "rm":
            return base.with(.rm(services: positionals, force: force))
        case "wait":
            return base.with(.wait(services: positionals, timeoutSeconds: timeoutSeconds))
        case "top":
            return base.with(.top(services: positionals))
        case "stats":
            return base.with(.stats(services: positionals))
        case "watch":
            try requireFile()
            return base.with(.watch(services: positionals))
        case "port":
            guard positionals.count >= 2 else { throw ParseError.missingArgument(command: commandName, name: "service and container-port") }
            guard let port = Int(positionals[1]) else { throw ParseError.invalidArgument(command: commandName, name: "container-port", value: positionals[1]) }
            return base.with(.port(service: positionals[0], containerPort: port))
        case "cp":
            guard positionals.count >= 2 else { throw ParseError.missingArgument(command: commandName, name: "source and destination") }
            return base.with(.cp(source: positionals[0], destination: positionals[1]))
        case "export":
            guard let service = positionals.first else { throw ParseError.missingArgument(command: commandName, name: "service") }
            guard let outputPath else { throw ParseError.missingRequiredFlag(command: commandName, flag: "--output") }
            return base.with(.export(service: service, outputPath: outputPath))
        default:
            throw ParseError.unknownCommand(commandName)
        }
    }
}

extension ProtocolRequest {
    fileprivate func with(_ command: Command) -> ProtocolRequest {
        var copy = self
        copy.command = command
        return copy
    }
}
