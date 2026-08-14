//
//  MagicVariable.swift
//  container-compose
//

import Foundation

/// A `SERVICE_*` variable from a Coolify service template, whose value that
/// platform generates rather than the template author writing it down.
///
/// This type only *understands* the convention — parsing names and finding
/// them in a document. It generates nothing and reads nothing, so it stays in
/// the pure core alongside the rest of planning; producing the values needs
/// randomness and a place to persist them, which lives above this layer.
///
/// Templates use two spellings for the same variable, which is the main thing
/// this has to reconcile:
///
///     environment:
///       - SERVICE_URL_AFFINE_3010                    # declaration, with port
///       - AFFINE_SERVER_EXTERNAL_URL=$SERVICE_URL_AFFINE   # reference, without
///
public struct MagicVariable: Equatable, Hashable, Sendable {

    /// The kinds whose values are actually generated.
    ///
    /// Deliberately closed: a great many template variables merely *start*
    /// with `SERVICE_` (`SERVICE_OPENAI_API_KEY`, `SERVICE_DISCORD_WEBHOOK`)
    /// and hold credentials only the user has. Generating a random value for
    /// one of those would replace "unset, fails loudly" with "set to nonsense,
    /// fails obscurely" — so anything not named here is left alone.
    public enum Kind: String, Equatable, Hashable, Sendable {
        case password
        case user
        case base64
        case realBase64
        case hex
        case url
        case fqdn

        /// The token as it appears between `SERVICE_` and the name.
        var token: String {
            switch self {
            case .password: return "PASSWORD"
            case .user: return "USER"
            case .base64: return "BASE64"
            case .realBase64: return "REALBASE64"
            case .hex: return "HEX"
            case .url: return "URL"
            case .fqdn: return "FQDN"
            }
        }

        /// URL and FQDN name a place, so a trailing number is the port to
        /// reach it on. The credential kinds name a secret, so a number means
        /// how much of it to make.
        var takesPortSuffix: Bool { self == .url || self == .fqdn }
    }

    /// The name to define, with any port suffix removed — what references in
    /// the document actually use.
    public let baseName: String
    public let kind: Kind
    /// Requested length, when the name carries one (`SERVICE_BASE64_64_APPKEY`).
    public let length: Int?
    /// Port from a URL/FQDN declaration (`SERVICE_URL_AFFINE_3010`).
    public let port: Int?

    /// The full name including any port suffix — the spelling a template
    /// declares. Equal to `baseName` when there is no port.
    ///
    /// Both spellings have to be defined: a file declares
    /// `SERVICE_URL_AFFINE_3010` and then references `$SERVICE_URL_AFFINE`,
    /// and some reference the suffixed form directly
    /// (`${SERVICE_FQDN_MINIO_9000}`). Defining only one leaves the other
    /// resolving to nothing.
    public var declaredName: String {
        port.map { "\(baseName)_\($0)" } ?? baseName
    }

    /// Parses one variable name. Returns nil when the name is not a generated
    /// kind, which is the common case and not an error.
    public init?(declaration name: String) {
        // Longest token first: REALBASE64 must not be read as BASE64 with a
        // stray REAL prefix.
        let matched = Kind.allCases
            .sorted { $0.token.count > $1.token.count }
            .first { name.hasPrefix("SERVICE_\($0.token)_") }
        guard let kind = matched else { return nil }

        var segments = name.split(separator: "_").map(String.init)
        // ["SERVICE", <TOKEN...>, ...rest]. REALBASE64 is one segment, so the
        // token always occupies exactly one after SERVICE.
        guard segments.count >= 3 else { return nil }
        segments.removeFirst(2)

        var length: Int?
        var port: Int?

        if kind.takesPortSuffix {
            // A trailing number is the port — but only if something is left to
            // name the variable, so `SERVICE_URL_8080` keeps its name.
            if segments.count >= 2, let trailing = Int(segments[segments.count - 1]) {
                port = trailing
                segments.removeLast()
            }
        } else if segments.count >= 2, let leading = Int(segments[0]) {
            // A leading number is the requested length.
            length = leading
            segments.removeFirst()
        }

        guard !segments.isEmpty else { return nil }

        self.kind = kind
        self.length = length
        self.port = port
        // Rebuilt rather than sliced from the original, so the declared form
        // and the referenced form converge on one name.
        let lengthPart = length.map { "\($0)_" } ?? ""
        self.baseName = "SERVICE_\(kind.token)_\(lengthPart)\(segments.joined(separator: "_"))"
    }

    /// Every generated variable a document needs, whether it declares them as
    /// bare environment entries or only mentions them in `${...}`.
    ///
    /// Deliberately a text scan, not a parse of the document tree: these
    /// appear inside interpolated strings (`postgres://${SERVICE_USER_DB}:...`)
    /// where a structural walk would have to re-implement interpolation to
    /// find them, and a template that fails to parse should still be
    /// translatable enough to tell the user what it needs.
    /// Keyed by the spelling as written, NOT by base name: one service can
    /// expose the same name on several ports —
    ///
    ///     - SERVICE_URL_PEPPERMINT_3000
    ///     - SERVICE_URL_PEPPERMINT_5003
    ///
    /// — and collapsing those to a single variable leaves whichever lost
    /// undefined, so a template referencing it gets an empty string. Callers
    /// resolve the bare spelling separately, since only they can decide which
    /// port it should mean.
    public static func scan(document: String) throws -> [MagicVariable] {
        var byName: [String: MagicVariable] = [:]

        for raw in candidateNames(in: document) {
            guard let variable = MagicVariable(declaration: raw) else { continue }
            byName[variable.declaredName] = variable
        }

        return byName.values.sorted {
            ($0.baseName, $0.port ?? 0) < ($1.baseName, $1.port ?? 0)
        }
    }

    /// The value this variable should take.
    ///
    /// `host` is what a URL or FQDN points at. Coolify resolves these through
    /// its reverse proxy to a real domain; there is no proxy here, so they
    /// resolve to the local host — which is the honest local equivalent, since
    /// the port the template asked for is published there.
    ///
    /// The generator is a parameter so this stays deterministic under test: a
    /// seeded generator gives repeatable values, while callers pass the system
    /// source for real ones.
    public func generatedValue<G: RandomNumberGenerator>(
        using generator: inout G,
        host: String = "localhost"
    ) -> String {
        switch kind {
        case .url:
            // No port means the template expects whatever the proxy serves on
            // 80, so the bare host URL is the faithful reading.
            return port.map { "http://\(host):\($0)" } ?? "http://\(host)"

        case .fqdn:
            // A hostname, never a URL: templates concatenate onto it
            // (`functions.$SERVICE_FQDN_APPWRITE`), and a scheme would corrupt
            // every one of those. The port is routing information for the
            // proxy, not part of the name, so it is deliberately dropped.
            return host

        case .user:
            // Short, letters-first: this lands in database usernames, which
            // reject a leading digit in more engines than not.
            return Self.random(length: length ?? 16, from: Self.letters, using: &generator)

        case .password:
            // Alphanumeric only. Punctuation here ends up inside connection
            // strings (`postgres://user:PASS@host`), where a `/`, `@` or `:`
            // silently changes what the URL means.
            return Self.random(length: length ?? 32, from: Self.alphanumerics, using: &generator)

        case .hex:
            return Self.random(length: length ?? 32, from: Self.hexDigits, using: &generator)

        case .base64:
            // Coolify's plain BASE64 is used where the value is pasted into
            // config and compared as text, so it stays URL-safe and unpadded —
            // no `+`, `/` or `=` to be escaped or trimmed by something
            // downstream.
            return Self.random(length: length ?? 32, from: Self.base64URLSafe, using: &generator)

        case .realBase64:
            // Genuine base64 of random bytes, padding included, for the
            // templates that decode it back to key material.
            let byteCount = length ?? 32
            let bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255, using: &generator) }
            return Data(bytes).base64EncodedString()
        }
    }

    private static let letters = Array("abcdefghijklmnopqrstuvwxyz")
    private static let alphanumerics = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let hexDigits = Array("0123456789abcdef")
    private static let base64URLSafe = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")

    private static func random<G: RandomNumberGenerator>(
        length: Int,
        from alphabet: [Character],
        using generator: inout G
    ) -> String {
        String((0..<max(1, length)).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] })
    }

    /// Every generated variable the document READS — `$NAME` or `${NAME}` —
    /// as opposed to merely declares.
    ///
    /// The distinction is the whole point of this being separate from
    /// `scan`. A bare `- SERVICE_FQDN_X_8080` entry is how these templates
    /// DECLARE a variable; nothing has gone wrong if it has no value yet.
    /// A `${SERVICE_PASSWORD_X}` inside another value is a READ, and an
    /// unfilled one silently becomes an empty password.
    ///
    /// Returns the names as written, since that is what a caller looks up
    /// in its variables — the port-suffixed spelling and the bare one are
    /// both defined by `translate`, so either resolves.
    public static func scanReferences(document: String) -> Set<String> {
        var names: Set<String> = []
        var characters = Array(document)
        var index = 0

        while index < characters.count {
            guard characters[index] == "$" else {
                index += 1
                continue
            }
            index += 1
            if index < characters.count, characters[index] == "{" { index += 1 }

            var name = ""
            while index < characters.count {
                let character = characters[index]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                name.append(character)
                index += 1
            }
            // Only names this module recognises as generated: everything
            // else is the user's own variable and unset is a normal state.
            if MagicVariable(declaration: name) != nil { names.insert(name) }
        }
        return names
    }

    /// Pulls out anything shaped like a `SERVICE_…` identifier, in any of the
    /// three spellings a compose file can carry it: bare, `$NAME`, `${NAME}`.
    private static func candidateNames(in document: String) -> [String] {
        var names: [String] = []
        var current = ""

        func flush() {
            if current.hasPrefix("SERVICE_") { names.append(current) }
            current = ""
        }

        for character in document {
            if character.isLetter || character.isNumber || character == "_" {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return names
    }
}

extension MagicVariable.Kind: CaseIterable {}
