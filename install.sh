#!/usr/bin/env bash
#
# container-compose installer.
#
# Builds a release binary from source and installs it onto PATH. This is a
# local source install, the same shape as `cargo install --path .` or
# `go install` — for a proper package-manager install, use the Homebrew tap
# instead: `brew tap paulmeller/container-compose && brew install
# container-compose`. This script is for iterating on a local checkout
# without waiting on a tap update.
#
# Installs one binary, container-compose, which both a human terminal and a
# non-Swift process (Port Authority's Projects section, or any other
# consumer) use — the latter via `container-compose --format ndjson ...`.
# See ProtocolRequest.extractFormat's doc comment for why this is one binary
# with a flag rather than two separate ones.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_NAME="container-compose"

echo "==> Checking prerequisites"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: no Swift toolchain found on PATH. Install Xcode or the Swift toolchain first." >&2
    exit 1
fi

if ! command -v container >/dev/null 2>&1; then
    echo "warning: Apple's \`container\` CLI was not found on PATH." >&2
    echo "         container-compose needs it at runtime (not to build this) — see https://github.com/apple/container" >&2
fi

echo "==> Building the release binary (this can take a minute or two)"
cd "$REPO_ROOT"
swift build -c release --product container-compose

BIN="$REPO_ROOT/.build/release/container-compose"

if [[ ! -x "$BIN" ]]; then
    echo "error: build did not produce the expected binary at .build/release/container-compose" >&2
    exit 1
fi

# Apple Silicon Homebrew's default, already on most users' PATH on this
# platform; /usr/local/bin (Intel Homebrew's own default) as the fallback.
if [[ -d /opt/homebrew/bin && -w /opt/homebrew/bin ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
elif [[ -d /usr/local/bin && -w /usr/local/bin ]]; then
    INSTALL_DIR="/usr/local/bin"
else
    echo "error: neither /opt/homebrew/bin nor /usr/local/bin exists and is writable." >&2
    echo "       create one of them (or fix its permissions), then re-run this script." >&2
    exit 1
fi

if [[ -e "$INSTALL_DIR/$BIN_NAME" ]]; then
    echo "==> Replacing existing $INSTALL_DIR/$BIN_NAME"
fi

echo "==> Installing to $INSTALL_DIR"
install -m 755 "$BIN" "$INSTALL_DIR/$BIN_NAME"

echo ""
echo "Installed: $INSTALL_DIR/$BIN_NAME"
echo ""

if ! command -v "$BIN_NAME" >/dev/null 2>&1; then
    echo "warning: $INSTALL_DIR does not appear to be on your PATH yet."
    echo "         add it to your shell profile, e.g.: export PATH=\"$INSTALL_DIR:\$PATH\""
else
    echo "Try it: $BIN_NAME capabilities"
    echo "For a machine consumer (e.g. Port Authority): $BIN_NAME --format ndjson ps --file compose.yml --project myapp"
fi
