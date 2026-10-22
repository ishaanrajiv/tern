#!/bin/sh
# Everything that should pass before a commit: Rust tests and lints, and the app build.
# Usage: scripts/check.sh
set -e
cd "$(dirname "$0")/.."

echo "== cargo test"
cargo test --quiet
echo "== cargo clippy"
cargo clippy --all-targets --quiet -- -D warnings
echo "== swift build"
# DebugHooks' screenshot API is deprecated but debug-only; any other warning fails.
# SwiftPM only reports warnings for files it compiles this run.
out=$(cd app && swift build 2>&1) || { echo "$out"; exit 1; }
warnings=$(echo "$out" | grep -E 'warning:' | grep -v 'DebugHooks.swift' || true)
if [ -n "$warnings" ]; then
    echo "$warnings"
    exit 1
fi
echo "== swift test"
(cd app && swift test --quiet)
echo "ok"
