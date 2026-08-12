//
//  main.swift
//  container-compose-cli
//
//  The human-facing CLI. Deliberately calls the SAME ProtocolRequest.parse
//  and ProtocolRunner that container-compose-protocol uses — not a
//  parallel implementation that happens to behave similarly. The only code
//  that exists purely for this target is CLIRenderer; everything else is
//  proof that this consumer has no access the protocol layer lacks.
//

import ComposeProtocol
import ComposeContainerRuntime
import ComposeCLIKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

let request: ProtocolRequest
do {
    request = try ProtocolRequest.parse(arguments)
} catch {
    // Plain text to stderr here, not a JSON error message: this binary is for
    // a human terminal, not a machine parser. (container-compose-protocol is
    // the one that speaks NDJSON on stdout for exactly that audience.)
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

let runner = ProtocolRunner(adapter: ContainerRuntimeAdapter())
let renderer = CLIRenderer()

// Same reasoning as the protocol binary: block buffering would silently turn
// live progress into output that only appears once the process exits.
setvbuf(stdout, nil, _IOLBF, 0)

let exitCode = await runner.run(request) { message in
    guard let line = renderer.render(message) else { return }
    print(line)
}

exit(exitCode)
