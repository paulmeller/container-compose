#!/usr/bin/env bash
#
# container-compose installer.
#
# Builds release binaries from source and installs them onto PATH — there
# is no hosted release yet (see docs/DESIGN.md's Naming section: the
# distributed binary name still needs to be settled before any public
# release, since it collides with an unrelated existing project's Homebrew
# formula), so this is a local source install, the same shape as
# `cargo install --path .` or `go install`, not a "curl a prebuilt binary"
# installer.
#
# Installs two binaries:
#   container-compose             the CLI you type in a terminal
#   container-compose-protocol    the NDJSON binary a non-Swift process
#                                  (Port Authority's Projects section,
#                                  or any other consumer) spawns by name —
#                                  keeps its build name; nothing spawns it
#                                  under any other one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLI_NAME="container-compose"

echo "==> Checking prerequisites"

if ! command -v swift >/dev/null 2>&1; then
    echo "error: no Swift toolchain found on PATH. Install Xcode or the Swift toolchain first." >&2
    exit 1
fi

if ! command -v container >/dev/null 2>&1; then
    echo "warning: Apple's \`container\` CLI was not found on PATH." >&2
    echo "         container-compose needs it at runtime (not to build this) — see https://github.com/apple/container" >&2
fi

echo "==> Building release binaries (this can take a minute or two)"
cd "$REPO_ROOT"
swift build -c release --product container-compose-cli
swift build -c release --product container-compose-protocol

CLI_BIN="$REPO_ROOT/.build/release/container-compose-cli"
PROTOCOL_BIN="$REPO_ROOT/.build/release/container-compose-protocol"

if [[ ! -x "$CLI_BIN" || ! -x "$PROTOCOL_BIN" ]]; then
    echo "error: build did not produce the expected binaries at .build/release/" >&2
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

if [[ -e "$INSTALL_DIR/$CLI_NAME" ]]; then
    echo "==> Replacing existing $INSTALL_DIR/$CLI_NAME"
fi

echo "==> Installing to $INSTALL_DIR"
install -m 755 "$CLI_BIN" "$INSTALL_DIR/$CLI_NAME"
install -m 755 "$PROTOCOL_BIN" "$INSTALL_DIR/container-compose-protocol"

echo ""
echo "Installed:"
echo "  $INSTALL_DIR/$CLI_NAME"
echo "  $INSTALL_DIR/container-compose-protocol"
echo ""

if ! command -v "$CLI_NAME" >/dev/null 2>&1; then
    echo "warning: $INSTALL_DIR does not appear to be on your PATH yet."
    echo "         add it to your shell profile, e.g.: export PATH=\"$INSTALL_DIR:\$PATH\""
else
    echo "Try it: $CLI_NAME capabilities"
fi
