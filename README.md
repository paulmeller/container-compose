# container-compose

[![ci](https://github.com/paulmeller/container-compose/actions/workflows/ci.yml/badge.svg)](https://github.com/paulmeller/container-compose/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A Compose engine for Apple's `container` runtime, built API-first: the engine
is the product, a CLI is one consumer of it. See [docs/DESIGN.md](docs/DESIGN.md)
for the full thesis and architecture.

## Where to get it

**Homebrew** (macOS):

    brew tap paulmeller/container-compose
    brew trust --tap paulmeller/container-compose
    brew install paulmeller/container-compose/container-compose

The `trust` step is not optional and the fully-qualified name is not
decoration. Homebrew silently ignores formulae from untrusted third-party
taps, and `brew install container-compose` — the bare name — then falls back
to an unrelated formula of the same name in homebrew-core. The result is a
successful-looking install of software you did not ask for. Being public does
not make a tap trusted; only *official* taps are trusted by default.

**From source:**

    git clone https://github.com/paulmeller/container-compose.git
    cd container-compose
    ./install.sh

Either way you also need Apple's own `container` runtime installed and
running (`container system start`) — this project drives it, it doesn't
replace it.

## Quick Start

Write a `compose.yml`:

```yaml
services:
  web:
    image: nginx
    ports:
      - "8080:80"
```

Then:

    container-compose up --file compose.yml --project myapp
    container-compose ps --file compose.yml --project myapp
    container-compose down --file compose.yml --project myapp --remove

Run `up` again with nothing changed and it reports `reused: true` and touches
nothing — see [docs/DESIGN.md](docs/DESIGN.md#reconciliation) for why that's
the whole point.

Add `--format ndjson` anywhere in argv for one JSON object per line on stdout
instead of formatted text. It's the same binary either way — a human terminal
and a non-Swift process both just call `container-compose` with a different
flag.

## Running a Coolify template

Self-hosted app templates written for [Coolify](https://coolify.io) use
`SERVICE_*` variables whose values that platform generates — passwords, usernames,
URLs — so the file alone will not run anywhere else. `translate` fills them in:

    container-compose translate --file affine.yaml
    container-compose up --file affine.yaml --project affine

It writes a `.env` beside the compose file and leaves the template itself
untouched, so nothing is lost to a reformatting pass. Values are stable across
runs: regenerating a password would change every service's config hash — and so
recreate every container — besides being rejected by any database already
initialised with the old one. Pass `--force` to rotate them deliberately.

Variables that only *look* generated (`SERVICE_OPENAI_API_KEY`,
`SERVICE_DISCORD_TOKEN`) are left alone, because they hold credentials only you
have; inventing a random value would turn "unset, fails loudly" into "set to
nonsense, fails obscurely". A template needing one says so by name when you run it.

`SERVICE_URL_*` and `SERVICE_FQDN_*` resolve to `localhost` and the port the
template asked for. Coolify routes those through a reverse proxy to a real
domain; there is no proxy here, and adding one is a
[non-goal](docs/DESIGN.md#non-goals).

## Commands

`up`, `down`, `build`, `pull`, `push`, `start`, `stop`, `restart`, `kill`,
`rm`, `wait`, `ps`, `ls`, `images`, `port`, `config`, `logs`, `top`, `stats`,
`cp`, `export`, `watch`, `exec`, `run`, `capabilities`, `translate` — 26
subcommands total.
Start with `container-compose capabilities`, which reports what your installed
runtime actually supports; see [docs/DESIGN.md](docs/DESIGN.md) for how
commands are routed internally.

## Development

    swift build
    swift test --filter "ComposeCoreTests|ComposeEngineTests|ComposeProtocolTests|ComposeCLIKitTests"  # fast, no daemon
    swift test --filter "ComposeContainerRuntimeLiveTests"                                              # needs `container system start`

See [docs/DESIGN.md](docs/DESIGN.md) for source layout and how the
reconciliation claim is proven layer by layer.

## Contributing

Issues and pull requests are welcome via the
[issue tracker](https://github.com/paulmeller/container-compose/issues).
