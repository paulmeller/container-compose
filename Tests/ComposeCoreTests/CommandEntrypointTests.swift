//
//  CommandEntrypointTests.swift
//  container-compose
//
//  `command` and `entrypoint` are the two keys where "not written" and
//  "written as empty" mean different things: an absent `entrypoint` leaves the
//  image's alone, while `entrypoint: []` resets it. Both were parsed through
//  the shared list helper, which returns `[]` for a missing key, so the
//  distinction was lost before it reached the runtime — the optionality on
//  `PlannedService` was never once `nil`.
//
//  Both also accept the string form, which Compose lexes the way a shell
//  would: `command: sh -c "echo hi"` is three arguments, not one. Passing the
//  whole line as a single argument is how walgit's compose.yaml failed —
//  aws-cli received `sh -c "..."` as one argv element and rejected it.
//

import Testing
import Foundation
@testable import ComposeCore

@Suite("command and entrypoint")
struct CommandEntrypointTests {

    private func service(_ body: String) throws -> PlannedService {
        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  svc:
                \(body.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
                """,
            options: PlanOptions(projectName: "proj")
        )
        return try #require(plan.service(named: "svc"))
    }

    @Test("An absent entrypoint is nil, not empty")
    func absentEntrypointIsNil() throws {
        let svc = try service("image: alpine")

        // Absent must stay distinguishable from `[]`: one leaves the image's
        // entrypoint alone, the other clears it.
        #expect(svc.entrypoint == nil)
        #expect(svc.command == nil)
    }

    @Test("An explicitly empty entrypoint is empty, not nil")
    func emptyEntrypointIsEmpty() throws {
        let svc = try service("""
            image: alpine
            entrypoint: []
            """)

        #expect(svc.entrypoint == [])
    }

    @Test("The string form of command is split the way a shell splits it")
    func scalarCommandIsShellSplit() throws {
        let svc = try service("""
            image: alpine
            command: echo hello
            """)

        #expect(svc.command == ["echo", "hello"])
    }

    @Test("Quoted sections of a string command stay one argument")
    func scalarCommandRespectsQuotes() throws {
        let svc = try service("""
            image: alpine
            command: sh -c "echo hello world"
            """)

        // The quoted run is a single argument — splitting it on spaces changes
        // what the container runs.
        #expect(svc.command == ["sh", "-c", "echo hello world"])
    }

    @Test("A folded block command is split, not passed as one argument")
    func foldedBlockCommandIsShellSplit() throws {
        // This is walgit's compose.yaml shape, which produced one giant argv
        // element and an `invalid choice` error from the image entrypoint.
        let svc = try service("""
            image: alpine
            command: >
              sh -c "echo hi"
            """)

        #expect(svc.command == ["sh", "-c", "echo hi"])
    }

    @Test("The list form of command is left exactly as written")
    func listCommandIsUntouched() throws {
        let svc = try service("""
            image: alpine
            command: ["sh", "-c", "echo hello world"]
            """)

        // The list form is already argv; it must never be re-split, or an
        // argument containing spaces would break apart.
        #expect(svc.command == ["sh", "-c", "echo hello world"])
    }

    @Test("The string form of entrypoint is shell-split too")
    func scalarEntrypointIsShellSplit() throws {
        let svc = try service("""
            image: alpine
            entrypoint: sh -c
            """)

        #expect(svc.entrypoint == ["sh", "-c"])
    }
}
