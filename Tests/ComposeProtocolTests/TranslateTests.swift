//
//  TranslateTests.swift
//  container-compose
//
//  Real temp directories and the real file provider, because the whole point
//  of this command is the file it leaves behind — an in-memory provider would
//  test everything except the part that matters.
//

import Testing
import Foundation
import ComposeCore
import ComposeTestSupport
@testable import ComposeProtocol

/// Lock-guarded: `onMessage` fires from the runner, not the calling context.
private final class TranslateMessageCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ProtocolMessage] = []

    func append(_ message: ProtocolMessage) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(message)
    }

    var messages: [ProtocolMessage] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite("translate", .serialized)
struct TranslateTests {

    private func withTempDirectory(_ body: (String) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-translate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.path)
    }

    @discardableResult
    private func translate(
        composePath: String,
        force: Bool = false
    ) async -> (messages: [ProtocolMessage], exitCode: Int32) {
        let runner = ProtocolRunner(adapter: FakeRuntimeAdapter())
        let request = ProtocolRequest(command: .translate(force: force), composeFilePath: composePath)
        let collector = TranslateMessageCollector()
        let exitCode = await runner.run(request) { collector.append($0) }
        return (collector.messages, exitCode)
    }

    private func write(_ contents: String, to path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func envValues(at path: String) -> [String: String] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        return Planner.parseEnvFile(contents)
    }

    private static let template = """
        services:
          app:
            image: nginx
            environment:
              - SERVICE_URL_APP_3010
              - DATABASE_URL=postgres://${SERVICE_USER_DB}:${SERVICE_PASSWORD_DB}@db:5432/app
          db:
            image: postgres
            environment:
              - SERVICE_USER_DB
              - SERVICE_PASSWORD_DB
        """

    @Test("Generates a value for every magic variable the template uses")
    func generatesValues() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)

            let (_, exitCode) = await translate(composePath: composePath)
            #expect(exitCode == 0)

            let values = envValues(at: directory + "/.env")
            #expect(values["SERVICE_USER_DB"]?.isEmpty == false)
            #expect(values["SERVICE_PASSWORD_DB"]?.isEmpty == false)
            // Both spellings, since the file declares one and may reference
            // the other.
            #expect(values["SERVICE_URL_APP"] == "http://localhost:3010")
            #expect(values["SERVICE_URL_APP_3010"] == "http://localhost:3010")
        }
    }

    @Test("Running twice keeps the values it already generated")
    func isIdempotent() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)

            await translate(composePath: composePath)
            let first = envValues(at: directory + "/.env")

            await translate(composePath: composePath)
            let second = envValues(at: directory + "/.env")

            // This is the property the whole design rests on: a regenerated
            // password changes each service's config hash — recreating every
            // container — and is rejected by any database already initialised
            // with the old one.
            #expect(first == second, "translate must not change values it has already generated")
            #expect(first["SERVICE_PASSWORD_DB"]?.isEmpty == false)
        }
    }

    @Test("--force regenerates, which is why it has to be asked for")
    func forceRegenerates() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)

            await translate(composePath: composePath)
            let before = envValues(at: directory + "/.env")

            await translate(composePath: composePath, force: true)
            let after = envValues(at: directory + "/.env")

            #expect(before["SERVICE_PASSWORD_DB"] != after["SERVICE_PASSWORD_DB"])
        }
    }

    @Test("A value the user set by hand is preserved")
    func respectsExistingValues() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)
            try write("SERVICE_PASSWORD_DB=chosen-by-hand\n", to: directory + "/.env")

            await translate(composePath: composePath)
            let values = envValues(at: directory + "/.env")

            #expect(values["SERVICE_PASSWORD_DB"] == "chosen-by-hand")
            // ...while still filling in the ones that were missing.
            #expect(values["SERVICE_USER_DB"]?.isEmpty == false)
        }
    }

    @Test("The generated values actually resolve when the template is planned")
    func valuesResolveIntoThePlan() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)
            await translate(composePath: composePath)

            let values = envValues(at: directory + "/.env")
            let plan = try Planner().plan(
                document: Self.template,
                options: PlanOptions(projectName: "p", directory: directory, variables: values)
            )

            let app = try #require(plan.service(named: "app"))
            let user = try #require(values["SERVICE_USER_DB"])
            let password = try #require(values["SERVICE_PASSWORD_DB"])

            // The real test of translation: the interpolated connection string
            // carries the generated credentials, not empty strings.
            #expect(app.environment["DATABASE_URL"] == "postgres://\(user):\(password)@db:5432/app")

            let db = try #require(plan.service(named: "db"))
            #expect(db.environment["SERVICE_PASSWORD_DB"] == password)
        }
    }

    @Test("A template with nothing to generate is reported, not treated as an error")
    func noMagicVariables() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write("services:\n  web:\n    image: nginx\n", to: composePath)

            let (messages, exitCode) = await translate(composePath: composePath)
            #expect(exitCode == 0)
            #expect(messages.contains { ($0.output ?? "").contains("no generated SERVICE_*") })
            // Nothing to write means no file appears out of nowhere.
            #expect(!FileManager.default.fileExists(atPath: directory + "/.env"))
        }
    }

    @Test("Variables that only look magic are left for the user to provide")
    func leavesUserSuppliedVariablesAlone() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(
                """
                services:
                  app:
                    image: nginx
                    environment:
                      - SERVICE_OPENAI_API_KEY
                      - SERVICE_PASSWORD_APP
                """,
                to: composePath
            )

            await translate(composePath: composePath)
            let values = envValues(at: directory + "/.env")

            #expect(values["SERVICE_PASSWORD_APP"]?.isEmpty == false)
            // Inventing a random OpenAI key would turn "unset, fails loudly"
            // into "set to nonsense, fails obscurely".
            #expect(values["SERVICE_OPENAI_API_KEY"] == nil)
        }
    }

    @Test("The env file is added to .gitignore when inside a git repository")
    func addsGitIgnoreEntry() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)
            // A bare marker is enough: the check is "is this a repo", and
            // committing real credentials is the thing being prevented.
            try FileManager.default.createDirectory(
                atPath: directory + "/.git", withIntermediateDirectories: true
            )

            await translate(composePath: composePath)

            let ignore = try String(contentsOfFile: directory + "/.gitignore", encoding: .utf8)
            #expect(ignore.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == ".env" })
        }
    }

    @Test("An existing .gitignore is appended to, not overwritten")
    func preservesExistingGitIgnore() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(Self.template, to: composePath)
            try FileManager.default.createDirectory(
                atPath: directory + "/.git", withIntermediateDirectories: true
            )
            try write("build/\n", to: directory + "/.gitignore")

            await translate(composePath: composePath)

            let ignore = try String(contentsOfFile: directory + "/.gitignore", encoding: .utf8)
            #expect(ignore.contains("build/"), "the user's existing entries must survive")
            #expect(ignore.contains(".env"))
        }
    }

    @Test("A bare reference alongside a ported declaration keeps the port")
    func bareReferenceInheritsThePort() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            // Exactly n8n's shape: declared with a port, referenced without.
            try write(
                """
                services:
                  n8n:
                    image: n8nio/n8n
                    environment:
                      - SERVICE_URL_N8N_5678
                      - WEBHOOK_URL=${SERVICE_URL_N8N}
                """,
                to: composePath
            )

            await translate(composePath: composePath)
            let values = envValues(at: directory + "/.env")

            // Generating the bare form independently yields "http://localhost",
            // silently dropping the port — every webhook would then point at
            // the wrong address, and nothing would say so.
            #expect(values["SERVICE_URL_N8N"] == "http://localhost:5678")
            #expect(values["SERVICE_URL_N8N_5678"] == "http://localhost:5678")
        }
    }

    @Test("Same name on two ports gets a value for each")
    func multiplePortsEachGetAValue() async throws {
        try await withTempDirectory { directory in
            let composePath = directory + "/compose.yml"
            try write(
                """
                services:
                  app:
                    image: nginx
                    environment:
                      - SERVICE_URL_APP_3000
                      - SERVICE_URL_APP_5003
                      - API_URL=${SERVICE_URL_APP_5003}
                """,
                to: composePath
            )

            await translate(composePath: composePath)
            let values = envValues(at: directory + "/.env")

            #expect(values["SERVICE_URL_APP_3000"] == "http://localhost:3000")
            #expect(values["SERVICE_URL_APP_5003"] == "http://localhost:5003")
            // The bare spelling resolves to the lowest port: arbitrary, but
            // deterministic, and better than leaving a reference empty.
            #expect(values["SERVICE_URL_APP"] == "http://localhost:3000")
        }
    }
}
