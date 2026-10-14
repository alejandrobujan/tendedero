#!/bin/bash
# Exercises folder switching and restoration without touching macOS preferences.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc Sources/Tendedero/InboxSettings.swift Tests/InboxSettings/main.swift -o "$WORK/test-inbox"
"$WORK/test-inbox"
