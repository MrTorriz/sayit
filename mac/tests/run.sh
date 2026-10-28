#!/usr/bin/env bash
# mac/tests/run.sh — build and run the macOS unit tests
#
# Usage:
#   mac/tests/run.sh
#
# Behavior:
#   - Compiles mac/tests/ConfigTests.swift together with
#     mac/Sources/Common/*.swift and mac/Sources/Agent/Config.swift, with the
#     swiftc flags mac/install.sh builds Sayit.app with, into a temporary
#     directory that is removed on exit.
#   - Runs the result there. Nothing is installed, signed or loaded, and no
#     microphone, clipboard or keystroke is touched.
#   - Needs only the Xcode Command Line Tools: no Xcode, no XCTest.
#
# Exit codes:
#   0  All checks passed
#   1  Not macOS, swiftc missing, a compile error, or at least one failed check

set -euo pipefail

# uname, not OSTYPE: the test suites set OSTYPE to exercise either platform.
[[ "$(uname -s)" == Darwin ]] || { echo "mac/tests/run.sh needs macOS" >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc missing - run: xcode-select --install" >&2; exit 1; }

MAC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/sayit-mac-tests.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
    "$MAC_DIR"/Sources/Common/*.swift "$MAC_DIR/Sources/Agent/Config.swift" \
    "$MAC_DIR/tests/ConfigTests.swift" -o "$WORK/config-tests" || exit 1

# The tests write their fixtures to NSTemporaryDirectory(), which follows TMPDIR.
TMPDIR="$WORK/" "$WORK/config-tests" || exit 1
