//
//  ContainerCLI.swift
//  container-compose
//

import Foundation

/// Runs the `container` binary and captures its output.
///
/// A thin process wrapper, kept separate from the adapter so the shelling-out
/// mechanics (argv construction, pipe draining, exit-code handling) are in one
/// place rather than repeated at every call site.
enum ContainerCLI {
    /// Run a command whose failure must not abort the caller — but must
    /// not vanish either.
    ///
    /// `try?` is the obvious way to write "best effort", and it is how
    /// the worst bugs in this project have hidden. A teardown that
    /// deleted nothing looked identical to one that deleted everything,
    /// so a network leaked on every test run until the accumulated pile
    /// stopped the daemon booting — nothing failed loudly at any point,
    /// and the only symptom surfaced much later, somewhere else.
    ///
    /// The diagnostic goes to stderr deliberately: stdout carries the
    /// NDJSON protocol, so a line there would corrupt the stream a
    /// machine consumer is parsing, and stderr is already captured and
    /// surfaced by those consumers.
    @discardableResult
    static func attempt(_ arguments: [String], describedAs description: String) -> Bool {
        do {
            _ = try run(arguments)
            return true
        } catch {
            FileHandle.standardError.write(Data("container-compose: could not \(description): \(error)\n".utf8))
            return false
        }
    }

    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool { exitCode == 0 }
    }

    enum Failure: Error, CustomStringConvertible {
        case nonZeroExit(command: [String], result: Result)
        case launchFailed(command: [String], underlying: Error)

        var description: String {
            switch self {
            case .nonZeroExit(let command, let result):
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                return "`container \(command.joined(separator: " "))` exited \(result.exitCode): \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
            case .launchFailed(let command, let underlying):
                return "failed to launch `container \(command.joined(separator: " "))`: \(underlying)"
            }
        }
    }

    @discardableResult
    static func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["container"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(command: arguments, underlying: error)
        }

        // Read before waiting: a child that writes more than the pipe buffer
        // (64KB on Darwin) and is never drained will deadlock against
        // waitUntilExit, since it blocks writing while this process blocks
        // waiting for it to exit.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = Result(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
        guard result.succeeded else {
            throw Failure.nonZeroExit(command: arguments, result: result)
        }
        return result
    }
}
