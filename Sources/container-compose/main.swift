//
//  main.swift
//  container-compose
//
//  The one binary. A human terminal and a non-Swift process (Port
//  Authority, spawning `container-compose --format ndjson ...`) are both
//  just callers that asked for a different `--format` — not two things this
//  file needs to tell apart beyond that one flag. Deliberately thin either
//  way: argv parsing and picking a renderer only. Every decision of
//  substance — argv parsing, planning, execution — lives in ComposeProtocol,
//  where it is unit-testable without spawning a process at all. If a change
//  here would need a test, it almost certainly belongs in that library
//  instead.
//

import ComposeProtocol
import ComposeContainerRuntime
import ComposeCLIKit
import Foundation

let rawArguments = Array(CommandLine.arguments.dropFirst())

let format: ProtocolRequest.OutputFormat
let arguments: [String]
do {
    (format, arguments) = try ProtocolRequest.extractFormat(rawArguments)
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

func reportRequestError(_ text: String) {
    switch format {
    case .ndjson:
        // A malformed invocation never reaches the runner, so it is
        // reported the same way any other request-level failure is — an
        // `error` message on stdout, not a stderr-only message an NDJSON
        // consumer would never see.
        let message = ProtocolMessage.errorMessage(text)
        if let data = try? JSONEncoder().encode(message), let line = String(data: data, encoding: .utf8) {
            print(line)
        }
    case .text:
        FileHandle.standardError.write(Data("error: \(text)\n".utf8))
    }
}

let request: ProtocolRequest
do {
    request = try ProtocolRequest.parse(arguments)
} catch {
    reportRequestError("\(error)")
    exit(1)
}

let runner = ProtocolRunner(adapter: ContainerRuntimeAdapter())
let renderer = CLIRenderer()
let encoder = JSONEncoder()

// Line-buffered explicitly: stdout is block-buffered when not a terminal,
// which would hold every line in a buffer until the process exits — making
// "streaming" NDJSON (or piped text) indistinguishable from a batch dump to
// any consumer reading it live. (The exact bug found and fixed in the prior
// fork's `watch` and `logs --follow`.)
setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ message: ProtocolMessage) {
    switch format {
    case .ndjson:
        guard let data = try? encoder.encode(message), let line = String(data: data, encoding: .utf8) else { return }
        print(line)
    case .text:
        guard let line = renderer.render(message) else { return }
        print(line)
    }
}

// exec/run inherit this process's stdio directly and never touch the
// ProtocolMessage stream at all — the documented exception
// `RuntimeAdapter.execPassthrough` and `runPassthrough(_:)` describe, in
// EITHER format: a live terminal session cannot be expressed as
// line-delimited JSON without breaking it, and there is likewise nothing
// for `CLIRenderer` to format. A resolution failure (no such service, no
// project) still gets reported through `reportRequestError`, since that
// part never reaches the passthrough at all.
switch request.command {
case .exec, .run:
    let (exitCode, error) = await runner.runPassthrough(request)
    if let error { reportRequestError(error) }
    exit(exitCode)
default:
    let exitCode = await runner.run(request, onMessage: emit)
    exit(exitCode)
}
