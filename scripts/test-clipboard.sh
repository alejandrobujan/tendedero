#!/bin/bash
# Runs the same synthetic test cases without SwiftPM/XCTest or a user pasteboard.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.build/clipboard-tests"
mkdir -p "$OUT/ModuleCache"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
swiftc -sdk "$SDK" -module-cache-path "$OUT/ModuleCache" \
  -D STANDALONE_TESTS -parse-as-library \
  Sources/Tendedero/ClipboardWatcher.swift Sources/Tendedero/Inbox.swift \
  Tests/TendederoTests/ClipboardWatcherTests.swift Tests/Standalone/ClipboardTestRunner.swift \
  -o "$OUT/clipboard-tests"
"$OUT/clipboard-tests"
