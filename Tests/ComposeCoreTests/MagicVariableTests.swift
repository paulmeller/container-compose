//
//  MagicVariableTests.swift
//  container-compose
//
//  Pins the naming rules against the forms that actually appear in the wild
//  (derived from ~365 real templates), because they are genuinely ambiguous:
//  a numeric segment means "length" in one position and "port" in another, and
//  the same variable is declared under one name and referenced under another.
//

import Testing
import Foundation
@testable import ComposeCore

@Suite("MagicVariable parsing")
struct MagicVariableTests {

    @Test("A credential variable is recognised with its default length")
    func credentialDefaults() throws {
        let variable = try #require(MagicVariable(declaration: "SERVICE_PASSWORD_POSTGRES"))
        #expect(variable.kind == .password)
        #expect(variable.baseName == "SERVICE_PASSWORD_POSTGRES")
        #expect(variable.length == nil)
        #expect(variable.port == nil)
    }

    @Test("A numeric segment straight after the type is a length, not part of the name")
    func lengthModifier() throws {
        // SERVICE_BASE64_64_APPKEY -> 64 bytes, named ..._APPKEY
        let sixtyFour = try #require(MagicVariable(declaration: "SERVICE_BASE64_64_APPKEY"))
        #expect(sixtyFour.kind == .base64)
        #expect(sixtyFour.length == 64)
        #expect(sixtyFour.baseName == "SERVICE_BASE64_64_APPKEY")

        let oneTwentyEight = try #require(MagicVariable(declaration: "SERVICE_BASE64_128_BUDIBASE"))
        #expect(oneTwentyEight.length == 128)
    }

    @Test("A trailing numeric segment on URL/FQDN is a port, and is not part of the base name")
    func portSuffix() throws {
        // Declared as SERVICE_URL_AFFINE_3010, referenced as $SERVICE_URL_AFFINE.
        let url = try #require(MagicVariable(declaration: "SERVICE_URL_AFFINE_3010"))
        #expect(url.kind == .url)
        #expect(url.port == 3010)
        #expect(url.baseName == "SERVICE_URL_AFFINE")

        let fqdn = try #require(MagicVariable(declaration: "SERVICE_FQDN_REDMINE_3000"))
        #expect(fqdn.kind == .fqdn)
        #expect(fqdn.port == 3000)
        #expect(fqdn.baseName == "SERVICE_FQDN_REDMINE")
    }

    @Test("URL and FQDN without a port keep their whole name")
    func noPortSuffix() throws {
        let url = try #require(MagicVariable(declaration: "SERVICE_URL_ADMIN"))
        #expect(url.port == nil)
        #expect(url.baseName == "SERVICE_URL_ADMIN")

        let fqdn = try #require(MagicVariable(declaration: "SERVICE_FQDN_STRAPI"))
        #expect(fqdn.port == nil)
        #expect(fqdn.baseName == "SERVICE_FQDN_STRAPI")
    }

    @Test("Every generated kind is recognised")
    func allKinds() throws {
        let cases: [(String, MagicVariable.Kind)] = [
            ("SERVICE_PASSWORD_A", .password),
            ("SERVICE_USER_A", .user),
            ("SERVICE_BASE64_A", .base64),
            ("SERVICE_REALBASE64_A", .realBase64),
            ("SERVICE_HEX_A", .hex),
            ("SERVICE_URL_A", .url),
            ("SERVICE_FQDN_A", .fqdn),
        ]
        for (name, expected) in cases {
            let variable = try #require(MagicVariable(declaration: name), "\(name) must parse")
            #expect(variable.kind == expected, "\(name) must be \(expected)")
        }
    }

    @Test("Names that only look magic are left alone")
    func nonMagicNames() {
        // These are ordinary variables template authors happened to name this
        // way — they hold the USER's API keys, and inventing a random value
        // for one would be worse than leaving it unset.
        #expect(MagicVariable(declaration: "SERVICE_OPENAI_API_KEY") == nil)
        #expect(MagicVariable(declaration: "SERVICE_DISCORD_WEBHOOK") == nil)
        #expect(MagicVariable(declaration: "DATABASE_URL") == nil)
        #expect(MagicVariable(declaration: "SERVICE") == nil)
        #expect(MagicVariable(declaration: "SERVICE_PASSWORD") == nil)
    }

    @Test("Declarations are found in a document's bare environment entries")
    func findsDeclarationsInDocument() throws {
        let document = """
            services:
              app:
                image: nginx
                environment:
                  - SERVICE_URL_APP_3010
                  - SERVICE_PASSWORD_APP
                  - REGULAR=1
                  - DATABASE_URL=postgres://${SERVICE_USER_DB}:${SERVICE_PASSWORD_DB}@db:5432/app
              db:
                image: postgres
                environment:
                  - SERVICE_USER_DB
                  - SERVICE_PASSWORD_DB
            """
        let found = try MagicVariable.scan(document: document)
        let names = Set(found.map(\.baseName))

        #expect(names.contains("SERVICE_URL_APP"))
        #expect(names.contains("SERVICE_PASSWORD_APP"))
        #expect(names.contains("SERVICE_USER_DB"))
        #expect(names.contains("SERVICE_PASSWORD_DB"))
        #expect(!names.contains("REGULAR"))
        #expect(!names.contains("DATABASE_URL"))
    }

    @Test("A variable referenced but never declared is still found")
    func findsReferenceOnlyVariables() throws {
        // Real templates reference ${SERVICE_PASSWORD_X} in one service while
        // declaring it in another — and some reference without declaring at
        // all. Missing those leaves an empty password in a connection string,
        // which fails at runtime rather than at translate time.
        let document = """
            services:
              app:
                image: nginx
                environment:
                  - DATABASE_URL=postgres://user:${SERVICE_PASSWORD_ONLYREFERENCED}@db/app
                  - SHORTHAND=$SERVICE_HEX_TOKEN
            """
        let found = try MagicVariable.scan(document: document)
        let names = Set(found.map(\.baseName))

        #expect(names.contains("SERVICE_PASSWORD_ONLYREFERENCED"))
        #expect(names.contains("SERVICE_HEX_TOKEN"))
    }

    @Test("Generated credentials avoid characters that would corrupt a connection string")
    func credentialsAreConnectionStringSafe() throws {
        // These land inside postgres://user:PASSWORD@host/db. A `/`, `@`, `:`
        // or `?` there does not fail loudly — it silently reparses the URL
        // into a different host, port or database.
        var generator = SystemRandomNumberGenerator()
        let dangerous = Set(":/@?#[]&= +%")

        for name in ["SERVICE_PASSWORD_A", "SERVICE_USER_A", "SERVICE_HEX_A", "SERVICE_BASE64_A"] {
            let variable = try #require(MagicVariable(declaration: name))
            for _ in 0..<50 {
                let value = variable.generatedValue(using: &generator)
                #expect(!value.isEmpty, "\(name) must generate something")
                #expect(
                    value.allSatisfy { !dangerous.contains($0) },
                    "\(name) generated \(value), which is unsafe inside a connection string"
                )
            }
        }
    }

    @Test("A generated username starts with a letter")
    func usernameStartsWithLetter() throws {
        // Several database engines reject an identifier beginning with a digit.
        var generator = SystemRandomNumberGenerator()
        let variable = try #require(MagicVariable(declaration: "SERVICE_USER_DB"))
        for _ in 0..<50 {
            let value = variable.generatedValue(using: &generator)
            #expect(value.first?.isLetter == true, "\(value) must start with a letter")
        }
    }

    @Test("Requested lengths are honoured")
    func lengthsAreHonoured() throws {
        var generator = SystemRandomNumberGenerator()
        let sixtyFour = try #require(MagicVariable(declaration: "SERVICE_BASE64_64_APPKEY"))
        #expect(sixtyFour.generatedValue(using: &generator).count == 64)

        let defaultLength = try #require(MagicVariable(declaration: "SERVICE_PASSWORD_A"))
        #expect(defaultLength.generatedValue(using: &generator).count == 32)
    }

    @Test("URL carries a scheme and port; FQDN is a bare hostname")
    func urlAndFqdnShapes() throws {
        var generator = SystemRandomNumberGenerator()

        let withPort = try #require(MagicVariable(declaration: "SERVICE_URL_AFFINE_3010"))
        #expect(withPort.generatedValue(using: &generator) == "http://localhost:3010")

        let withoutPort = try #require(MagicVariable(declaration: "SERVICE_URL_ADMIN"))
        #expect(withoutPort.generatedValue(using: &generator) == "http://localhost")

        // Templates concatenate onto an FQDN (`functions.$SERVICE_FQDN_X`), so
        // a scheme or port here would corrupt every such use.
        let fqdn = try #require(MagicVariable(declaration: "SERVICE_FQDN_REDMINE_3000"))
        #expect(fqdn.generatedValue(using: &generator) == "localhost")
    }

    @Test("Two generated values of the same kind differ")
    func valuesAreNotConstant() throws {
        var generator = SystemRandomNumberGenerator()
        let variable = try #require(MagicVariable(declaration: "SERVICE_PASSWORD_A"))
        let values = Set((0..<20).map { _ in variable.generatedValue(using: &generator) })
        #expect(values.count == 20, "every generated password must be distinct")
    }

    @Test("Both the ported declaration and the bare reference are reported")
    func declarationAndReferenceBothReported() throws {
        let document = """
            services:
              app:
                image: nginx
                environment:
                  - SERVICE_URL_AFFINE_3010
                  - AFFINE_SERVER_EXTERNAL_URL=$SERVICE_URL_AFFINE
            """
        let found = try MagicVariable.scan(document: document)
        let affine = found.filter { $0.baseName == "SERVICE_URL_AFFINE" }

        // Both spellings appear in the file, so both need a value; deciding
        // what the bare one means is the caller's job, not the parser's.
        #expect(Set(affine.map(\.declaredName)) == ["SERVICE_URL_AFFINE_3010", "SERVICE_URL_AFFINE"])
        #expect(affine.contains { $0.port == 3010 })
    }

    @Test("One name exposed on several ports keeps every port")
    func multiplePortsForOneName() throws {
        // Real template (peppermint): collapsing these to one variable left
        // whichever lost undefined, so a reference to it resolved to empty.
        let document = """
            services:
              app:
                image: nginx
                environment:
                  - SERVICE_URL_PEPPERMINT_3000
                  - SERVICE_URL_PEPPERMINT_5003
                  - API_URL=${SERVICE_URL_PEPPERMINT_5003}
            """
        let found = try MagicVariable.scan(document: document)
        let ports = found
            .filter { $0.baseName == "SERVICE_URL_PEPPERMINT" }
            .compactMap(\.port)
            .sorted()

        #expect(ports == [3000, 5003], "every declared port must survive")
    }
}

@Suite("Unresolved generated variables")
struct UnresolvedGeneratedVariableTests {

    private func plan(_ document: String, variables: [String: String] = [:]) throws -> Plan {
        try Planner(files: InMemoryProvider([:])).plan(
            document: document,
            options: PlanOptions(projectName: "proj", variables: variables)
        )
    }

    @Test("Planning refuses a template whose generated variables were never filled in")
    func refusesUnresolvedGeneratedVariables() throws {
        // Without this the references resolve to empty strings and the app
        // starts with a blank username and password — which looks like a
        // broken app rather than an unconfigured one, and says nothing
        // about the step that was missed.
        let document = """
            services:
              app:
                image: openclaw
                environment:
                  - AUTH_USERNAME=$SERVICE_USER_OPENCLAW
                  - AUTH_PASSWORD=$SERVICE_PASSWORD_OPENCLAW
            """

        #expect(throws: PlanError.self) { try plan(document) }

        do {
            _ = try plan(document)
            Issue.record("expected planning to refuse")
        } catch let error as PlanError {
            let text = "\(error)"
            // The message has to name the fix, not just the problem.
            #expect(text.contains("translate"))
            #expect(text.contains("SERVICE_"))
        }
    }

    @Test("Values supplied by any means satisfy the check")
    func suppliedValuesAreAccepted() throws {
        let document = """
            services:
              app:
                image: openclaw
                environment:
                  - AUTH_PASSWORD=$SERVICE_PASSWORD_OPENCLAW
            """
        // `translate` writes these into a .env, but the check is about
        // whether a value EXISTS — set it in the shell and it is just as
        // resolved.
        let result = try plan(document, variables: ["SERVICE_PASSWORD_OPENCLAW": "hunter2"])
        let app = try #require(result.service(named: "app"))
        #expect(app.environment["AUTH_PASSWORD"] == "hunter2")
    }

    @Test("A variable that only looks generated is left to the user")
    func nonGeneratedVariablesAreNotChecked() throws {
        // SERVICE_OPENAI_API_KEY holds the user's own key: unset is a
        // normal state that Compose already reports its own way, and
        // refusing to plan over it would be this check overreaching.
        let document = """
            services:
              app:
                image: openclaw
                environment:
                  - OPENAI_API_KEY=${SERVICE_OPENAI_API_KEY}
                  - PLAIN=${SOME_OTHER_VARIABLE}
            """
        let result = try plan(document)
        let app = try #require(result.service(named: "app"))
        #expect(app.environment["OPENAI_API_KEY"] == "")
    }

    @Test("A bare declaration alone does not trip the check")
    func bareDeclarationIsNotAReference() throws {
        // `- SERVICE_FQDN_X_8080` with nothing referencing it is how these
        // templates DECLARE a variable. Refusing on the declaration would
        // make every untranslated template unplannable even when nothing
        // consumes the value — including `config`, which is how you would
        // inspect the file to find that out.
        let document = """
            services:
              app:
                image: openclaw
                environment:
                  - SERVICE_FQDN_OPENCLAW_8080
            """
        let result = try plan(document)
        #expect(result.service(named: "app") != nil)
    }
}
