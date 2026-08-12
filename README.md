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
                               shape), ProtocolRunner (resolves a request into
                               a Plan and executes it), and
                               ProtocolRequest.extractFormat (the global
                               `--format text|ndjson` flag, order-independent,
                               parsed separately from the per-command argv).
  ComposeCLIKit/               formats a ProtocolMessage stream as human-
                               readable text — the `--format text` path.
  container-compose/          the one binary. ~40 lines: argv -> a format
                               plus a ProtocolRequest, run it, print each
                               ProtocolMessage either as NDJSON or through
                               CLIRenderer depending on `--format`, exit code
                               from the runner. Line-buffered explicitly —
                               block buffering would turn "streaming" into
                               "dumped at exit". A human terminal and a
                               non-Swift process (Port Authority) are both
                               just callers of this SAME binary with a
                               different flag, not two build targets —
                               proof by construction that `--format text`
                               has no capability `--format ndjson` lacks.
Tests/
  ComposeCoreTests/            76 tests, ~15ms. No daemon — includes a
                               real-filesystem suite (temp dirs, no
                               InMemoryProvider) specifically so path
                               resolution can't hide behind that fake's
                               deliberately lenient basename fallback.
  ComposeEngineTests/          26 tests against the in-memory fake, ~1s
                               (dominated by one deliberate `wait` timeout).
  ComposeProtocolTests/        62 tests, request parsing + wire mapping + full
                               runs against the fake — no process spawn —
                               plus DirectoryWatcher's own suite, against
                               real temp directories and real kqueue events.
  ComposeCLIKitTests/          20 tests of pure rendering logic.
  ComposeContainerRuntimeLiveTests/
                               14 tests against a REAL `container` daemon —
                               the one place a wrong runtime assumption
                               could hide from every test above it. Caught
                               three live-only bugs this way: a one-off
                               `run` container colliding with the managed
                               one, `./`-prefixed watch paths truncating
                               synced filenames, and uppercase project
                               names producing an invalid OCI image tag.
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
  shared code) spawns `container-compose --format ndjson`, parses NDJSON
  line by line, and asserts `reused: true` on the second `up`. This is the
  proof that matters for the motivating case — Port Authority is Zig and
  cannot link a Swift library at all.

## Building and testing

```sh
swift build
swift test --filter "ComposeCoreTests|ComposeEngineTests|ComposeProtocolTests|ComposeCLIKitTests"  # fast, no daemon
swift test --filter "ComposeContainerRuntimeLiveTests"                                              # needs `container system start`
```

## Trying it

```sh
swift build
.build/debug/container-compose capabilities
.build/debug/container-compose up --file compose.yml --project myapp
.build/debug/container-compose up --file compose.yml --project myapp   # run again: reports "reused", touches nothing
.build/debug/container-compose ps --file compose.yml --project myapp
.build/debug/container-compose logs --file compose.yml --project myapp --follow web
.build/debug/container-compose exec --file compose.yml --project myapp web sh
.build/debug/container-compose down --file compose.yml --project myapp --remove
```

Add `--format ndjson` (anywhere in argv, before or after the subcommand) to
get one JSON object per line on stdout instead of formatted text — that is
the entire difference `--format` makes, with one deliberate exception:
`exec`/`run` inherit the calling process's stdio directly regardless of
`--format`, since a live terminal session cannot be expressed as
line-delimited JSON without breaking it — documented at
`RuntimeAdapter.execPassthrough`.

## Command surface

Full parity with the fork's 25 subcommands, routed one of two ways
(`ComposeProtocol/ProtocolRunner.swift` has the exact split):

- **Engine-owned** (need `Reconciler` and/or concurrent multi-service
  orchestration with the typed event stream): `up`, `down`, `build`, `pull`,
  `push`, `start`, `stop`, `restart`, `kill`, `rm`, `wait`.
- **Direct to the adapter** (act on an already-existing single container, or
  are pure observation — routing them through Engine's reconcile-and-wave
  machinery would buy nothing): `ps`, `ls`, `images`, `port`, `config`,
  `logs`, `top`, `stats`, `cp`, `export`, `watch`.
- **Passthrough exception**: `exec`, `run` — inherited-stdio process
  execution, never NDJSON, for the reason above.

`watch` is event-driven: `DirectoryWatcher` (`ComposeProtocol`, one
kqueue-backed `DispatchSourceFileSystemObject` per directory, recursive,
debounced) triggers a rescan on real filesystem activity, with a 5s
safety-net rescan alongside it for the one thing directory-level watching
can't see (a same-inode in-place write with no rename). A rescan diffs via
`WatchPlanner` (`ComposeCore`, pure snapshot diffing) and syncs,
syncs-and-restarts, or rebuilds-and-recreates per rule.

## Status

Core, Engine, the real adapter, the protocol layer and a CLI all exist and
are tested end to end, including from a genuinely non-Swift consumer, with
the full command surface above wired through every layer. Port Authority
(the Zig GUI that motivated the protocol layer in the first place) has a
Projects section that spawns `container-compose --format ndjson` and drives
it — the last item in the design doc's sequencing, and the real test of
whether any of this was shaped correctly. It lives on a branch there, not
yet merged or visually verified interactively (only through its own test
suite and a clean process launch), since that verification happens in that
project's own repo.

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
