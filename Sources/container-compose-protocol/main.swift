//
//  main.swift
//  container-compose-protocol
//
//  The actual process a non-Swift consumer spawns. Deliberately thin: parse
//  argv, hand off to ProtocolRunner, write NDJSON to stdout as messages
//  arrive, exit with the runner's status code. Every decision of substance —
//  argv parsing, planning, execution — lives in ComposeProtocol, where it is
//  unit-testable without spawning a process at all. If a change here would
//  need a test, it almost certainly belongs in that library instead.
//

import ComposeProtocol
import ComposeContainerRuntime
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

let request: ProtocolRequest
do {
    request = try ProtocolRequest.parse(arguments)
} catch {
    // A malformed invocation never reaches the runner, so it is reported the
    // same way any other request-level failure is — an `error` message on
    // stdout, not a raw crash or a stderr-only message a consumer parsing
    // NDJSON would never see.
    let message = ProtocolMessage.errorMessage("\(error)")
    if let data = try? JSONEncoder().encode(message), let line = String(data: data, encoding: .utf8) {
        print(line)
    }
    exit(1)
}

let runner = ProtocolRunner(adapter: ContainerRuntimeAdapter())

let encoder = JSONEncoder()
// Line-buffered explicitly: stdout is block-buffered when not a terminal,
// which would hold every line in a buffer until the process exits — making
// "streaming" NDJSON indistinguishable from a batch dump to any consumer
// reading it live. (The exact bug found and fixed in the prior fork's `watch`
// and `logs --follow`.)
setvbuf(stdout, nil, _IOLBF, 0)

func emit(_ message: ProtocolMessage) {
    guard let data = try? encoder.encode(message), let line = String(data: data, encoding: .utf8) else { return }
    print(line)
}

// exec/run inherit this process's stdio directly and never touch the NDJSON
// stream — the documented exception `RuntimeAdapter.execPassthrough` and
// `runPassthrough(_:)` describe. A resolution failure (no such service, no
// project) still gets reported as a normal `error` message, since that part
// never reaches the passthrough at all.
switch request.command {
case .exec, .run:
    let (exitCode, error) = await runner.runPassthrough(request)
    if let error { emit(.errorMessage(error)) }
    exit(exitCode)
default:
    let exitCode = await runner.run(request, onMessage: emit)
    exit(exitCode)
}
