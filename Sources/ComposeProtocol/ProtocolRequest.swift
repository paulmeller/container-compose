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
        case down(remove: Bool)
        case capabilities
    }

    public var command: Command
    /// Required for `.up`/`.down`; unused for `.capabilities`, which reports
    /// what the runtime can do independent of any particular project.
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

        public var description: String {
            switch self {
            case .noCommand:
                return "no command given (expected: up, down, or capabilities)"
            case .unknownCommand(let name):
                return "unknown command '\(name)' (expected: up, down, or capabilities)"
            case .missingValue(let flag):
                return "'\(flag)' requires a value"
            case .unknownFlag(let flag):
                return "unknown flag '\(flag)'"
            case .missingRequiredFlag(let command, let flag):
                return "'\(command)' requires \(flag)"
            }
        }
    }

    /// Parses argv (excluding the executable name at index 0).
    ///
    /// Hand-rolled rather than a dependency: the surface is small and fixed,
    /// and this is exactly the kind of decision-of-substance that belongs in
    /// this library, testable without spawning a process — not in `main.swift`.
    public static func parse(_ arguments: [String]) throws -> ProtocolRequest {
        guard let commandName = arguments.first else { throw ParseError.noCommand }
        var rest = Array(arguments.dropFirst())

        var composeFilePath: String?
        var projectName: String?
        var envFilePath: String?
        var profiles: Set<String> = []
        var services: [String] = []
        var remove = false

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
            default:
                if token.hasPrefix("-") {
                    throw ParseError.unknownFlag(token)
                }
                // A bare token is a service name — only meaningful for `up`,
                // ignored (not rejected) for other commands so a consumer
                // building argv generically does not need per-command logic.
                services.append(token)
            }
        }

        switch commandName {
        case "capabilities":
            return ProtocolRequest(command: .capabilities)
        case "up":
            guard composeFilePath != nil else { throw ParseError.missingRequiredFlag(command: "up", flag: "--file") }
            return ProtocolRequest(
                command: .up(services: services),
                composeFilePath: composeFilePath,
                projectName: projectName,
                envFilePath: envFilePath,
                profiles: profiles
            )
        case "down":
            guard composeFilePath != nil else { throw ParseError.missingRequiredFlag(command: "down", flag: "--file") }
            return ProtocolRequest(
                command: .down(remove: remove),
                composeFilePath: composeFilePath,
                projectName: projectName,
                envFilePath: envFilePath,
                profiles: profiles
            )
        default:
            throw ParseError.unknownCommand(commandName)
        }
    }
}
