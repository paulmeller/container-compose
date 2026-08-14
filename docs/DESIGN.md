# container-compose — design

## The design in one paragraph

The **engine is the product**; the CLI is one consumer of it. A pure planning
layer turns a compose file into an immutable `Plan`, a reconciling execution
engine emits typed events rather than printing, and a process-level protocol
lets non-Swift consumers drive all of it without linking Swift at all.
Anything that needs to *drive* Compose — a GUI, an IDE plugin, a CI system, an
agent — talks to that machine contract as the primary interface, not as an
afterthought bolted on with a `--json` flag.

## Why an engine is shaped differently from a CLI

These are not stylistic preferences. Each one is a place where CLI-shaped
assumptions actively break an embedding consumer.

| Concern | CLI assumption | What an engine needs |
|---|---|---|
| **Output** | Print progressively to stdout | Emit a typed **event stream**; rendering is the consumer's job |
| **Partial failure** | Exit non-zero, prose explains | Per-service outcome as a **first-class result** — "3 of 5 up, these 2 failed, here's why" |
| **Long operations** | Block until done | **Observable and cancellable**: per-service progress, and a way to stop |
| **Errors** | A message and exit 1 | **Typed and classified** — config vs runtime vs timeout vs unsupported — so a consumer can decide what's actionable |
| **State** | Rediscover from scratch each invocation | A queryable **project model**, cheap to refresh |
| **Intent** | `up` means "recreate" | **Reconcile**: make reality match the file, touching only what differs |
| **Capabilities** | Discover limits by hitting them | Expose **what this runtime can and cannot do** as data |

The last row comes straight from measurement: of ~95 Compose service keys,
roughly 40 are expressible on this runtime, ~4 parse but can never function
(`restart`, `configs`, `secrets`, most of `deploy`), and the rest have no
equivalent at all. Surfacing that as data lets a GUI grey out an unsupported
control and explain why, before the user commits — rather than leaving them to
discover it by hitting the limit at runtime.

## Layering

Four layers, each with a rule about what it may not do.

```
┌─────────────────────────────────────────────────────────┐
│  CLI            thin renderer of the event stream        │
│                 may not contain translation logic        │
├─────────────────────────────────────────────────────────┤
│  Protocol       NDJSON over stdio / unix socket          │
│                 process-level; language-agnostic         │
├─────────────────────────────────────────────────────────┤
│  Engine         executes plans, owns reconciliation      │
│                 emits events; performs all I/O           │
├─────────────────────────────────────────────────────────┤
│  Core           compose file -> immutable Plan           │
│                 pure; no I/O, no printing, no runtime    │
└─────────────────────────────────────────────────────────┘
```

**Core** is pure: a compose document in, a `Plan` out. Interpolation, `extends`
resolution, profile gating, dependency ordering, and the mapping to runtime
arguments all live here, and none of it touches the filesystem, the network, or
the clock. This is what makes the hard parts testable without a daemon: the
translation logic can be exercised in milliseconds, with no containers started
at all.

**Engine** is the only layer that performs I/O. It takes a `Plan`, reconciles it
against observed reality, and emits events. It never prints.

**Protocol** is what makes this usable from Zig, Node, Python or anything else:
a line-delimited JSON stream over stdio. This exists because the first real
consumer (Port Authority) is written in Zig and cannot link a Swift library. A
Swift-only API would have failed its actual use case on day one.

**CLI** renders events into human output. It is deliberately the *last* layer
and has no privileged access: **if the CLI needs something the protocol does not
expose, the protocol is wrong.** That constraint is the main defense against the
engine quietly regrowing a CLI-shaped bias.

## Source layout

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
  ComposeEngineTests/          32 tests against the in-memory fake, ~1s
                               (dominated by one deliberate `wait` timeout).
  ComposeProtocolTests/        68 tests, request parsing + wire mapping + full
                               runs against the fake — no process spawn —
                               plus DirectoryWatcher's own suite, against
                               real temp directories and real kqueue events.
  ComposeCLIKitTests/          20 tests of pure rendering logic.
  ComposeContainerRuntimeLiveTests/
                               18 tests against a REAL `container` daemon —
                               the one place a wrong runtime assumption
                               could hide from every test above it. Caught
                               five live-only bugs this way: a one-off
                               `run` container colliding with the managed
                               one, `./`-prefixed watch paths truncating
                               synced filenames, uppercase project names
                               producing an invalid OCI image tag, services
                               referencing a network by its compose key
                               while it is created under its resolved name,
                               and uppercase project names again — this
                               time producing a network name the runtime
                               rejects outright.
```

## Command routing

25 subcommands, routed one of two ways
(`ComposeProtocol/ProtocolRunner.swift` has the exact split):

- **Engine-owned** (need `Reconciler` and/or concurrent multi-service
  orchestration with the typed event stream): `up`, `down`, `build`, `pull`,
  `push`, `start`, `stop`, `restart`, `kill`, `rm`, `wait`.
- **Direct to the adapter** (act on an already-existing single container, or
  are pure observation — routing them through Engine's reconcile-and-wave
  machinery would buy nothing): `ps`, `ls`, `images`, `port`, `config`,
  `logs`, `top`, `stats`, `cp`, `export`, `watch`.
- **Passthrough exception**: `exec`, `run` — inherited-stdio process
  execution, never NDJSON, since a live terminal session cannot be expressed
  as line-delimited JSON without breaking it — documented at
  `RuntimeAdapter.execPassthrough`.

`watch` is event-driven: `DirectoryWatcher` (`ComposeProtocol`, one
kqueue-backed `DispatchSourceFileSystemObject` per directory, recursive,
debounced) triggers a rescan on real filesystem activity, with a 5s
safety-net rescan alongside it for the one thing directory-level watching
can't see (a same-inode in-place write with no rename). A rescan diffs via
`WatchPlanner` (`ComposeCore`, pure snapshot diffing) and syncs,
syncs-and-restarts, or rebuilds-and-recreates per rule.

## How the reconciliation claim is tested

The claim above — an already-correct, already-running container is left
alone — is provable in layers:

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

## The contract

Two things a consumer needs, neither of which exists today.

### 1. Capability manifest

Answers "what will actually work here?" *before* anything runs.

```json
{
  "runtime": { "name": "apple/container", "version": "1.1.0" },
  "keys": {
    "ports":    { "support": "full" },
    "cap_add":  { "support": "full" },
    "restart":  { "support": "none",
                  "reason": "no restart-policy flag exists in this runtime" },
    "deploy":   { "support": "partial",
                  "supported": ["resources.limits.cpus", "resources.limits.memory"],
                  "reason": "replicas and placement are orchestrator concepts" }
  }
}
```

Derived from the runtime actually present, not hardcoded — so it stays honest
when Apple adds a flag.

### 2. Event stream

Every operation emits events rather than returning only at the end.

```jsonl
{"event":"plan",           "services":["db","api","web"],"waves":[["db"],["api"],["web"]]}
{"event":"service.state",  "service":"db", "state":"pulling","image":"postgres:16"}
{"event":"service.state",  "service":"db", "state":"starting"}
{"event":"service.ready",  "service":"db", "container":"proj-db","health":"healthy"}
{"event":"service.failed", "service":"api","reason":"image_not_found","detail":"..."}
{"event":"done",           "success":false,"ready":["db"],"failed":["api"],"skipped":["web"]}
```

`skipped` matters: when `api` fails, `web` never gets attempted, and a consumer
must be able to distinguish that from "tried and failed". Today that information
does not exist anywhere.

## Non-goals

Scope discipline, stated up front:

- **Not a Docker Compose clone.** Where the runtime cannot express a key, the
  engine reports it as unsupported. It does not emulate Swarm.
- **Not a PaaS.** No domains, TLS, git deploys, or remote hosts. Local runtime only.
- **Not a GUI.** Port Authority is a consumer, developed separately.
- **No screen-scraping.** The engine talks to the runtime's own APIs and
  structured output. If something is only available as prose, that is a gap to
  raise upstream, not to parse.

## Reconciliation

The behavioral centerpiece.

A "recreate everything, always" `up` is destructive and slow for a GUI that
polls, or for a user who clicks Start twice. What is needed is "ensure
running".

So the engine's primitive is: **given this desired state and this observed
state, what is the minimal set of actions?**

- Container absent → create and start
- Present, running, config unchanged → **no action**
- Present, stopped, config unchanged → start
- Present, config changed → recreate (and say *what* changed)

"Config changed" is decidable because the plan is a value: hash the resolved
service definition, store it as a label, compare on the next reconcile.

## Networks

Declared networks are ensured once, before the first wave — not per service.
A container that references a network which does not exist fails at create
time, and every service in the project would fail the same way for the same
reason; failing once, up front, says it once and leaves nothing half-created.

The rules, and why each one is what it is:

- **Non-external networks are this project's to create.** They resolve to
  `<project>_<key>`, lowercased — the runtime rejects an uppercase network
  name outright, so a project named `MyApp` would otherwise fail at create
  time with nothing pointing at the cause. They are labelled with
  `com.docker.compose.project`, the same ownership rule the containers follow,
  so teardown can tell what this project made from what merely happened to be
  present.
- **External networks are required, never created.** Creating one silently
  would invent infrastructure the user said already existed, and hide a
  genuine misconfiguration behind a network with no containers on it. Absent
  means the run stops, with a message naming the network and both ways out.
- **An explicit `name:` is used exactly as written.** The user named a
  specific network; silently renaming it would attach the project to something
  other than what they asked for.
- **A service's `networks:` list is resolved in the plan, not the adapter.**
  The compose file says `backend`; the runtime only knows `proj_backend`.
  Resolving it in the pure layer is what keeps the Plan's contract honest —
  what a service references is what actually exists.

Reused rather than recreated, like everything else here: an existing network
is reported as found, and `networkReady` carries `created` so a consumer can
say which happened rather than guess.

## Runtime facts worth writing down

Behaviors of Apple's `container` runtime that shaped the adapter, and that are
easy to lose an afternoon to:

- There is no `--restart` flag and no `--add-host`.
- `/etc/hosts` cross-patching is the workable DNS fallback.
- `container ls --format json` carries compose labels, which is what makes
  observation (and therefore reconciliation) possible at all.
- `nslookup` bypasses `/etc/hosts` entirely, so it will happily mislead anyone
  using it to test DNS.

## Sequencing

Each step is independently useful, and none is wasted if the next is abandoned.

1. **Core + Plan** with the existing test corpus ported. No runtime needed.
2. **Capability manifest** — small, immediately useful, novel on its own.
3. **Engine + events** for `up`/`down`, reconcile-first from the start.
4. **Protocol** over stdio; prove it by driving the engine from a non-Swift script.
5. **CLI** as a renderer. Its completeness is the test of the protocol's.
6. **Port Authority integration** — the real consumer, and the honest test of
   whether any of this was shaped correctly.

## Status

Core, Engine, the real adapter, the protocol layer and a CLI all exist and
are tested end to end, including from a genuinely non-Swift consumer, with
the full command surface above wired through every layer. Port Authority
(the Zig GUI that motivated the protocol layer in the first place) has a
Projects section that spawns `container-compose --format ndjson` and drives
it — the last item in the sequencing above, and the real test of whether any
of this was shaped correctly. It lives on a branch there, not yet merged or
visually verified interactively (only through its own test suite and a clean
process launch), since that verification happens in that project's own repo.

## Naming

The project is named `container-compose`.

Note for release planning: a same-named formula already exists on Homebrew
for an unrelated project, and colliding with it has already caused real
problems once — a bare `brew install container-compose` silently fell back to
the other formula via Homebrew's tap-trust behavior instead of installing
this one. The *distributed* name likely needs to differ from the project
name even if the project name does not change. Worth settling before any
public release, not after.
