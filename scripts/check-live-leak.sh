#!/usr/bin/env bash
#
# Run the live suite and fail if the machine has more on it afterwards.
#
# LeakLiveTests asserts that `down --remove` cleans up after itself. This
# asserts the weaker but broader thing no in-suite test can: that the
# WHOLE run — every suite, including ones that drive the adapter directly
# and tear down by hand — ends where it started.
#
# It is the check that was missing. Each live test leaked its project's
# network, silently, because every teardown call swallowed its failure.
# Nothing noticed until several hundred accumulated networks stopped the
# daemon from booting, which took every running container down with it.
#
# Swift Testing runs suites in parallel and has no cross-suite teardown
# hook, so this lives in a script rather than in the suite.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

count() {
  # `container <kind> list` prints a header line, hence the tail.
  container "$@" 2>/dev/null | tail -n +2 | wc -l | tr -d ' '
}

snapshot() {
  echo "networks=$(count network list) volumes=$(count volume list) containers=$(count list --all)"
}

if ! container system status >/dev/null 2>&1; then
  echo "container daemon is not running; skipping the live leak check"
  exit 0
fi

before="$(snapshot)"
echo "before: $before"

# The suite's own result matters too: a run that fails early would leak
# nothing and pass this check for the wrong reason.
status=0
swift test --filter Live || status=$?

after="$(snapshot)"
echo "after:  $after"

if [ "$before" != "$after" ]; then
  echo
  echo "FAIL: the live suite left resources behind."
  echo "  before: $before"
  echo "  after:  $after"
  echo
  echo "Every leaked network is a launchd service the daemon starts at boot."
  echo "Left to accumulate, they stop it starting at all."
  echo
  echo "Leftovers:"
  container network list 2>/dev/null | tail -n +2 | awk '{print "  network " $1}'
  exit 1
fi

if [ "$status" -ne 0 ]; then
  echo "live suite failed (exit $status)"
  exit "$status"
fi

echo "OK: no resources leaked"
