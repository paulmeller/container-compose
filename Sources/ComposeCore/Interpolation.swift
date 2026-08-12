//
//  Interpolation.swift
//  container-compose
//

import Foundation

/// Supplies file contents to the planner.
///
/// `extends: {file:}` and `env_file:` both need to read files, which would
/// otherwise make planning impure and untestable without a fixture directory.
/// Injecting the reads instead means tests can plan entire multi-file projects
/// from in-memory strings, and the planner never touches the filesystem itself.
public protocol ComposeFileProvider: Sendable {
    /// - Returns: The file's contents, or nil when it does not exist.
    func contents(atPath path: String) -> String?
}

/// Reads from the real filesystem. The production implementation.
public struct FileSystemProvider: ComposeFileProvider {
    public init() {}

    public func contents(atPath path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Reads from a dictionary. Used by tests, and by any consumer planning a
/// document it holds in memory rather than on disk.
public struct InMemoryProvider: ComposeFileProvider {
    private let files: [String: String]

    public init(_ files: [String: String]) {
        self.files = files
    }

    public func contents(atPath path: String) -> String? {
        if let exact = files[path] { return exact }
        // Tolerate a leading ./ and directory prefixes so callers can use
        // natural relative paths without mirroring a directory layout.
        let name = (path as NSString).lastPathComponent
        return files[name]
    }
}

/// Compose `${VAR}` interpolation.
///
/// Deliberately takes its variables as a parameter rather than reading the
/// process environment internally: a planner that silently depends on ambient
/// state cannot be tested reproducibly, and two callers planning the same
/// document must get the same plan.
public enum Interpolation {

    public enum Failure: Error, Equatable, Sendable {
        /// `${VAR:?message}` where VAR is unset — the spec's "fail loudly" form.
        case required(variable: String, message: String)
    }

    /// Resolves every `${...}` reference in `value`.
    ///
    /// Supports the Compose forms:
    ///   - `${VAR}`             — empty when unset
    ///   - `${VAR:-default}`    — default when unset or empty
    ///   - `${VAR-default}`     — default only when unset
    ///   - `${VAR:?error}`      — throws when unset or empty
    ///   - `${VAR?error}`       — throws only when unset
    ///   - `$$`                 — a literal `$`
    public static func resolve(_ value: String, variables: [String: String]) throws -> String {
        var out = ""
        var index = value.startIndex

        while index < value.endIndex {
            let character = value[index]
            guard character == "$" else {
                out.append(character)
                index = value.index(after: index)
                continue
            }

            let next = value.index(after: index)
            guard next < value.endIndex else {
                // A trailing lone `$` is literal.
                out.append(character)
                index = next
                continue
            }

            // `$$` escapes a literal dollar sign.
            if value[next] == "$" {
                out.append("$")
                index = value.index(after: next)
                continue
            }

            if value[next] == "{" {
                guard let close = findClosingBrace(in: value, from: next) else {
                    // Unterminated: emit literally rather than swallowing input.
                    out.append(contentsOf: value[index...])
                    index = value.endIndex
                    continue
                }
                let body = String(value[value.index(after: next)..<close])
                out += try expand(body, variables: variables)
                index = value.index(after: close)
                continue
            }

            // Bare `$VAR` form.
            var cursor = next
            while cursor < value.endIndex, value[cursor].isLetter || value[cursor].isNumber || value[cursor] == "_" {
                cursor = value.index(after: cursor)
            }
            if cursor == next {
                out.append(character)
                index = next
                continue
            }
            let name = String(value[next..<cursor])
            out += variables[name] ?? ""
            index = cursor
        }

        return out
    }

    /// Resolves every value in a mapping.
    public static func resolve(_ values: [String: String], variables: [String: String]) throws -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in values {
            out[try resolve(key, variables: variables)] = try resolve(value, variables: variables)
        }
        return out
    }

    /// Resolves every element of a list.
    public static func resolve(_ values: [String], variables: [String: String]) throws -> [String] {
        try values.map { try resolve($0, variables: variables) }
    }

    /// Handles nesting, so `${OUTER:-${INNER}}` finds the correct `}`.
    private static func findClosingBrace(in value: String, from braceIndex: String.Index) -> String.Index? {
        var depth = 0
        var index = braceIndex
        while index < value.endIndex {
            if value[index] == "{" { depth += 1 }
            if value[index] == "}" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func expand(_ body: String, variables: [String: String]) throws -> String {
        // Split on the first operator, honoring the `:` prefix that makes an
        // empty value count as unset.
        for op in [":-", ":?", ":+", "-", "?", "+"] {
            guard let range = body.range(of: op) else { continue }
            // `:-` must win over `-`; the ordering above ensures that, but a
            // two-character operator found at the same position as its
            // one-character form still needs the longer match.
            if op.count == 1, body.hasPrefix(String(body.prefix(upTo: range.lowerBound)) + ":") { continue }

            let name = String(body[body.startIndex..<range.lowerBound])
            let argument = String(body[range.upperBound...])
            let treatEmptyAsUnset = op.hasPrefix(":")
            let raw = variables[name]
            let isSet = treatEmptyAsUnset ? !(raw ?? "").isEmpty : raw != nil

            switch op {
            case ":-", "-":
                return isSet ? (raw ?? "") : try resolve(argument, variables: variables)
            case ":?", "?":
                if isSet { return raw ?? "" }
                throw Failure.required(variable: name, message: argument)
            case ":+", "+":
                return isSet ? try resolve(argument, variables: variables) : ""
            default:
                break
            }
        }

        return variables[body] ?? ""
    }
}
