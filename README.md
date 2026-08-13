# container-compose

A Compose engine for Apple's `container` runtime, built API-first: the engine
is the product, a CLI is one consumer of it. See [docs/DESIGN.md](docs/DESIGN.md)
for the full thesis and architecture.

## Where to get it

**Homebrew** (macOS):

    brew tap paulmeller/container-compose
    brew install paulmeller/container-compose/container-compose

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

## Commands

`up`, `down`, `build`, `pull`, `push`, `start`, `stop`, `restart`, `kill`,
`rm`, `wait`, `ps`, `ls`, `images`, `port`, `config`, `logs`, `top`, `stats`,
`cp`, `export`, `watch`, `exec`, `run`, `capabilities` — 25 subcommands total.
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
