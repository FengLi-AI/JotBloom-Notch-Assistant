#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jotbloom-codex-check.XXXXXX")"
trap 'rm -rf "$CHECK_DIR"' EXIT
swiftc "$ROOT/JotBloom/Companion/CodexCompletionReader.swift" "$ROOT/scripts/check-codex-events.swift" -o "$CHECK_DIR/check"
"$CHECK_DIR/check"
