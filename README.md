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
  ComposeCore/              compose document -> immutable Plan. Pure — no I/O.
  ComposeEngine/             executes a Plan: observe, reconcile, execute, emit events.
  ComposeContainerRuntime/  RuntimeAdapter for Apple's `container` CLI.
Tests/
  ComposeCoreTests/          43 tests, ~5ms. No daemon.
  ComposeEngineTests/        13 tests against an in-memory fake adapter, ~3ms. No daemon.
  ComposeContainerRuntimeLiveTests/
                              4 tests against a REAL `container` daemon.
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

## Building and testing

```sh
swift build
swift test --filter "ComposeCoreTests|ComposeEngineTests"   # fast, no daemon
swift test --filter "ComposeContainerRuntimeLiveTests"       # needs `container system start`
```

## Status

Early. `Core` and `Engine` are in place and tested; `build:` services are not
yet wired into `ContainerRuntimeAdapter`. No protocol layer or CLI yet — see
the design doc's sequencing section for what's next.

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
