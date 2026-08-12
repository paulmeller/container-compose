# container-compose

A Compose engine for Apple's `container` runtime, built API-first: the engine
is the product, a CLI is one consumer of it.

See [docs/DESIGN.md](docs/DESIGN.md) for the full thesis. In short: existing
tools for this runtime are CLI-shaped — they print prose and exit — so
anything that wants to *drive* Compose (a GUI, an agent, CI) has to
screen-scrape or reimplement the translation. This inverts that: a pure
planning layer, a reconciling execution engine that emits typed events instead
of printing, and a process-level protocol so non-Swift consumers (this
project's actual motivating case is a Zig GUI) can drive it without linking
Swift at all.

## Layout

```
Sources/
  ComposeCore/                compose document -> immutable Plan, and the pure
                               Reconciler. No I/O anywhere in this target.
  ComposeEngine/               executes a Plan: observe, reconcile, execute,
                               emit a live event stream (not batched).
  ComposeContainerRuntime/    RuntimeAdapter for Apple's `container` CLI.
  ComposeTestSupport/         FakeRuntimeAdapter, shared by every test target
                               that needs to drive Engine without a daemon.
  ComposeProtocol/             the wire contract: ProtocolMessage (flat, tagged,
                               NOT a serialization of EngineEvent's Swift
                               shape) and ProtocolRunner, which resolves a
                               request into a Plan and executes it.
  container-compose-protocol/ the actual binary a non-Swift process spawns.
                               ~30 lines: argv -> ProtocolRequest, print each
                               ProtocolMessage as one NDJSON line, exit code
                               from the runner. Line-buffered explicitly —
                               block buffering would turn "streaming" into
                               "dumped at exit".
  ComposeCLIKit/               formats the same message stream as human-
                               readable text. The only code that exists
                               purely for the CLI.
  container-compose-cli/      the human CLI. Calls the IDENTICAL
                               ProtocolRequest.parse / ProtocolRunner the
                               protocol binary uses — proof by construction
                               that it has no capability the protocol lacks.
Tests/
  ComposeCoreTests/            52 tests, ~7ms. No daemon.
  ComposeEngineTests/          13 tests against the in-memory fake, ~3ms.
  ComposeProtocolTests/        20 tests, request parsing + wire mapping + full
                               runs against the fake — no process spawn.
  ComposeCLIKitTests/          13 tests of pure rendering logic.
  ComposeContainerRuntimeLiveTests/
                               4 tests against a REAL `container` daemon —
                               the one place a wrong runtime assumption
                               could hide from every test above it.
```

## The central claim, and how it's tested

Existing tooling treats `up` as "stop and recreate everything, always." This
engine instead reconciles: given a desired `Plan` and what's actually running,
compute the minimal set of actions. An already-correct, already-running
container is left alone.

That claim is provable in layers:

- `Reconciler` (in `ComposeCore`) is a pure function — `(Plan, [ObservedContainer]) -> [ReconcileAction]`
  — tested in milliseconds with no runtime involved at all.
- `Engine` is tested against an in-memory `FakeRuntimeAdapter`, so its
  orchestration (wave sequencing, concurrency, event ordering, the
  skip-vs-fail distinction) is proven without a daemon either.
- `ComposeContainerRuntimeLiveTests` runs the *same* `Engine` against the real
  `ContainerRuntimeAdapter` and a live daemon, and asserts the thing that
  actually matters: run `up` twice, and the second run reports `reused: true`
  with the identical container — verified against the event stream and
  independently against `container ls`.
- The same claim is verified a second time across the actual process
  boundary the project exists to serve: a plain Python script (no Swift, no
  shared code) spawns `container-compose-protocol`, parses NDJSON line by
  line, and asserts `reused: true` on the second `up`. This is the proof
  that matters for the motivating case — Port Authority is Zig and cannot
  link a Swift library at all.

## Building and testing

```sh
swift build
swift test --filter "ComposeCoreTests|ComposeEngineTests|ComposeProtocolTests|ComposeCLIKitTests"  # fast, no daemon
swift test --filter "ComposeContainerRuntimeLiveTests"                                              # needs `container system start`
```

## Trying it

```sh
swift build
.build/debug/container-compose-cli capabilities
.build/debug/container-compose-cli up --file compose.yml --project myapp
.build/debug/container-compose-cli up --file compose.yml --project myapp   # run again: reports "reused", touches nothing
.build/debug/container-compose-cli down --file compose.yml --project myapp --remove
```

`container-compose-protocol` takes the identical arguments and emits one
JSON object per line on stdout instead of formatted text — that is the
entire difference between the two binaries.

## Status

Core, Engine, the real adapter, the protocol layer and a CLI all exist and
are tested end to end, including from a genuinely non-Swift consumer. Known
gaps, stated rather than hidden:

- `build:` services are not yet wired into `ContainerRuntimeAdapter.createContainer`
  — it throws a clear error rather than silently doing nothing.
- `ProtocolMessage.serviceReady` is reused by `down` to report a torn-down
  container, and the CLI renders it as "ready" either way — a real if minor
  wording gap, since the message carries no notion of which command produced it.
- No `ps`/`logs`/`exec` yet: neither Engine nor the protocol expose them, so
  the CLI correctly cannot either — the whole point of the layering is that
  the CLI's surface can never silently exceed what the protocol supports.
- No Port Authority integration yet — the last item in the design doc's
  sequencing, and the real test of whether any of this was shaped correctly.

## Provenance

No code here is copied from any existing implementation. The architecture —
pure planning, an event-emitting engine, capability-as-data, reconciliation —
is original. What carries over is hard-won *knowledge* about the runtime
(which flags exist, which Compose keys have no equivalent, the DNS fallback's
sharp edges), gathered while building and extending a fork of
[Container-Compose](https://github.com/Mcrich23/Container-Compose) (MIT) that
preceded this project. That fork remains separate, keeps its own license and
attribution, and several of its fixes are worth upstreaming independently of
this project's outcome.
