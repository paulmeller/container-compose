# container-compose — design thesis

## The thesis in one paragraph

Every Compose implementation for Apple's `container` runtime is **CLI-shaped**:
it prints prose, blocks, and exits. Anything that wants to *drive* Compose —
a GUI, an IDE plugin, a CI system, an agent — has two bad options: screen-scrape
human output, or reimplement the translation itself. Both happen today. This
project inverts the shape: the **engine is the product**, the CLI is one
consumer of it, and the machine contract is the primary interface rather than an
afterthought bolted on with a `--json` flag.

## Why a GUI-first engine is shaped differently

These are not stylistic preferences. Each one is a place where CLI assumptions
actively break an embedding consumer.

| Concern | CLI assumption | What an engine needs |
|---|---|---|
| **Output** | Print progressively to stdout | Emit a typed **event stream**; rendering is the consumer's job |
| **Partial failure** | Exit non-zero, prose explains | Per-service outcome as a **first-class result** — "3 of 5 up, these 2 failed, here's why" |
| **Long operations** | Block until done | **Observable and cancellable**: per-service progress, and a way to stop |
| **Errors** | A message and exit 1 | **Typed and classified** — config vs runtime vs timeout vs unsupported — so a consumer can decide what's actionable |
| **State** | Rediscover from scratch each invocation | A queryable **project model**, cheap to refresh |
| **Intent** | `up` means "recreate" | **Reconcile**: make reality match the file, touching only what differs |
| **Capabilities** | Discover limits by hitting them | Expose **what this runtime can and cannot do** as data |

The last row is the one nobody does, and it comes straight from measurement: of
~95 Compose service keys, roughly 40 are expressible on this runtime, ~4 parse
but can never function (`restart`, `configs`, `secrets`, most of `deploy`), and
the rest have no equivalent at all. Today you discover that by reading warnings
in a terminal. An engine should let a GUI grey out the unsupported control and
explain why, before the user commits.

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
the clock. This is what makes the hard parts testable without a daemon — today's
equivalent logic can only be tested by starting real containers.

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

The behavioral centerpiece, and the sharpest break from CLI semantics.

`up` today unconditionally stops and deletes existing containers, then recreates
them — there is no "ensure running". For a GUI that polls or a user who clicks
Start twice, that is destructive and slow.

The engine's primitive is instead: **given this desired state and this observed
state, what is the minimal set of actions?**

- Container absent → create and start
- Present, running, config unchanged → **no action**
- Present, stopped, config unchanged → start
- Present, config changed → recreate (and say *what* changed)

"Config changed" is decidable because the plan is a value: hash the resolved
service definition, store it as a label, compare on the next reconcile.

## What is reused, and what is not

Stated plainly, because it bears on authorship.

**Not reused:** no code is copied. The architecture above — pure core, event
stream, protocol layer, capability manifest, reconciliation — is a different
design from any existing implementation, all of which are CLI-first.

**Reused:** hard-won knowledge about the runtime, gathered by building the fork
that preceded this. That the runtime has no `--restart` and no `--add-host`;
that `/etc/hosts` cross-patching is the workable DNS fallback; that
`container ls --format json` carries compose labels; that `nslookup` bypasses
`/etc/hosts` and misleads anyone testing DNS. Facts about a third-party runtime
are not anyone's intellectual property, and rediscovering them by hand would
help no one.

**Attribution:** the prior fork of
[Container-Compose](https://github.com/Mcrich23/Container-Compose) (MIT) remains
separate and keeps its notices. Fixes made there that stand on their own —
notably `down` removing containers, and consistent `${VAR}` interpolation —
should be upstreamed regardless of this project's outcome. That is the honest
move and costs nothing.

## Sequencing

Each step is independently useful, and none is wasted if the next is abandoned.

1. **Core + Plan** with the existing test corpus ported. No runtime needed.
2. **Capability manifest** — small, immediately useful, novel on its own.
3. **Engine + events** for `up`/`down`, reconcile-first from the start.
4. **Protocol** over stdio; prove it by driving the engine from a non-Swift script.
5. **CLI** as a renderer. Its completeness is the test of the protocol's.
6. **Port Authority integration** — the real consumer, and the honest test of
   whether any of this was shaped correctly.

## Naming

The project is named `container-compose`.

Note for release planning: an unrelated MIT project of the same name exists
(`Mcrich23/Container-Compose`), and ships a `container-compose` binary via
Homebrew. Publishing under this name would collide with it at the binary and
formula level, so the *distributed* name needs to differ even though the
project name does not. Worth settling before any public release, not after.
