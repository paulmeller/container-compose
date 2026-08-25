//
//  CreateArgumentsTests.swift
//  container-compose
//
//  `container create` takes `[options] <image> [command...]`: everything after
//  the image is the container's own argv, not a flag. `--entrypoint` was
//  appended *after* the image, so the runtime never saw it as an option —
//  verified against the installed runtime, which reported
//  `arguments: ["--entrypoint", "sh"]` with the executable still the image's
//  own entrypoint. Every `entrypoint:` in every compose file was silently
//  inert, and the flag leaked into the container's arguments on top.
//
//  Found running walgit's compose.yaml, whose one-shot bucket-creation service
//  clears the aws-cli image's entrypoint to run a shell:
//
//      entrypoint: []
//      command: > ...
//
//  which failed with `Found invalid choice 'sh -c "..."'` — the image's `aws`
//  entrypoint receiving the whole shell line as one argument.
//
//  These assert the argv the product builds, not one reassembled by hand, so
//  argument *order* is covered rather than mere presence.
//

import Testing
import Foundation
@testable import ComposeContainerRuntime
@testable import ComposeCore

@Suite("container create argv")
struct CreateArgumentsTests {

    /// Plans a one-service document and returns the argv the adapter would run.
    /// `hostsPath` is fixed so the vector is deterministic.
    private func argv(_ serviceBody: String, service: String = "svc") throws -> [String] {
        let plan = try Planner(files: InMemoryProvider([:])).plan(
            document: """
                services:
                  \(service):
                \(serviceBody.split(separator: "\n").map { "    \($0)" }.joined(separator: "\n"))
                """,
            options: PlanOptions(projectName: "proj")
        )
        let planned = try #require(plan.service(named: service))
        return ContainerRuntimeAdapter.createArguments(
            for: planned, image: planned.image ?? "img", projectName: "proj", hostsPath: "/tmp/hosts"
        )
    }

    /// The index the image sits at — everything before is options, everything
    /// after is the container's argv.
    private func imageIndex(_ args: [String], image: String) throws -> Int {
        try #require(args.firstIndex(of: image))
    }

    @Test("--entrypoint is an option, so it precedes the image")
    func entrypointPrecedesImage() throws {
        let args = try argv("""
            image: alpine
            entrypoint: ["sh"]
            """)

        let image = try imageIndex(args, image: "alpine")
        let flag = try #require(args.firstIndex(of: "--entrypoint"))
        // After the image it is not a flag at all — it becomes argv the
        // container is started with, and the image entrypoint still runs.
        #expect(flag < image)
        #expect(args[flag + 1] == "sh")
    }

    @Test("A multi-element entrypoint keeps every element")
    func multiElementEntrypointIsNotTruncated() throws {
        let args = try argv("""
            image: alpine
            entrypoint: ["sh", "-c", "echo hi"]
            """)

        // `--entrypoint` takes a single executable, so the tail belongs with
        // the command argv after the image — dropping it silently changes what
        // runs.
        let image = try imageIndex(args, image: "alpine")
        #expect(args[image...].contains("-c"))
        #expect(args[image...].contains("echo hi"))
    }

    @Test("entrypoint: [] clears the image entrypoint and runs the command directly")
    func emptyEntrypointClearsTheImageEntrypoint() throws {
        let args = try argv("""
            image: alpine
            entrypoint: []
            command: ["sh", "-c", "echo hi"]
            """)

        // The compose spec says an empty entrypoint resets the image's. This
        // runtime has no "clear" flag, so the command's own executable has to
        // become the entrypoint or the image's runs instead.
        let image = try imageIndex(args, image: "alpine")
        let flag = try #require(args.firstIndex(of: "--entrypoint"))
        #expect(flag < image)
        #expect(args[flag + 1] == "sh")
        // `sh` was promoted to the entrypoint; it must not also be repeated as
        // the first argument.
        #expect(Array(args[(image + 1)...]) == ["-c", "echo hi"])
    }

    @Test("A service with no entrypoint gets no --entrypoint flag")
    func absentEntrypointEmitsNoFlag() throws {
        let args = try argv("""
            image: alpine
            command: ["echo", "hi"]
            """)

        // Absent and empty must stay distinguishable: absent leaves the image's
        // entrypoint alone.
        #expect(!args.contains("--entrypoint"))
        let image = try imageIndex(args, image: "alpine")
        #expect(Array(args[(image + 1)...]) == ["echo", "hi"])
    }

    @Test("The image is the last option-free element before the command")
    func nothingLeaksAfterTheImageButTheCommand() throws {
        let args = try argv("""
            image: alpine
            entrypoint: ["sh"]
            command: ["-c", "echo hi"]
            """)

        let image = try imageIndex(args, image: "alpine")
        // The original bug put `--entrypoint sh` here, which the runtime
        // handed to the container as arguments.
        #expect(Array(args[(image + 1)...]) == ["-c", "echo hi"])
    }
}
