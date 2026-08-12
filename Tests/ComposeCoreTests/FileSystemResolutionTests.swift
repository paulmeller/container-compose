//
//  FileSystemResolutionTests.swift
//  container-compose
//
//  Every other Core test uses InMemoryProvider, which tolerates a bare
//  filename fallback (see its doc comment) that masked a real path-resolution
//  bug: env_file/build.context resolution dropped the compose directory's own
//  last path component whenever it lacked a trailing slash. Real
//  FileSystemProvider has no such fallback — a wrong path here just returns
//  nil, exactly like it would for an actual user's compose file. These tests
//  use a real temporary directory specifically so nothing can mask that class
//  of bug again. Still fast: real disk I/O in a temp dir, no container
//  runtime involved.
//

import Testing
import Foundation
import ComposeCore

@Suite("Path resolution against a real filesystem")
struct FileSystemResolutionTests {

    private func withTempProjectDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cc-fs-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("env_file resolves relative to the compose file's own directory, not its basename dropped")
    func envFileResolvesAgainstRealDirectory() throws {
        try withTempProjectDirectory { directory in
            try "DB_HOST=box\n".write(to: directory.appendingPathComponent("db.env"), atomically: true, encoding: .utf8)

            let result = try Planner(files: FileSystemProvider()).plan(
                document: """
                    services:
                      api:
                        image: alpine
                        env_file: [db.env]
                    """,
                options: PlanOptions(projectName: "proj", directory: directory.path)
            )

            #expect(result.service(named: "api")?.environment["DB_HOST"] == "box")
        }
    }

    @Test("A nested env_file path resolves correctly against a real, multi-component directory")
    func nestedEnvFileResolvesAgainstRealDirectory() throws {
        try withTempProjectDirectory { directory in
            let envDir = directory.appendingPathComponent("config")
            try FileManager.default.createDirectory(at: envDir, withIntermediateDirectories: true)
            try "MODE=production\n".write(to: envDir.appendingPathComponent("prod.env"), atomically: true, encoding: .utf8)

            let result = try Planner(files: FileSystemProvider()).plan(
                document: """
                    services:
                      api:
                        image: alpine
                        env_file: [config/prod.env]
                    """,
                options: PlanOptions(projectName: "proj", directory: directory.path)
            )

            #expect(result.service(named: "api")?.environment["MODE"] == "production")
        }
    }

    @Test("build.context resolves to the compose file's own directory, not its parent")
    func buildContextResolvesAgainstRealDirectory() throws {
        try withTempProjectDirectory { directory in
            let result = try Planner(files: FileSystemProvider()).plan(
                document: """
                    services:
                      app:
                        build: ./service
                    """,
                options: PlanOptions(projectName: "proj", directory: directory.path)
            )

            let build = try #require(result.service(named: "app")?.build)
            #expect(build.context == directory.appendingPathComponent("service").path)
        }
    }
}
