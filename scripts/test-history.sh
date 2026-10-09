#!/bin/bash
# Only synthetic files, isolated preferences and unposted events.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.build/history-tests"
mkdir -p "$OUT/ModuleCache"
SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
# CLT's macOS 27 SDK requires a SwiftUI macro plugin provided only by Xcode.
if [ -z "${SDKROOT:-}" ] && [ ! -d /Applications/Xcode.app ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]; then
  SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
fi
SOURCES=()
for source in Sources/Tendedero/*.swift; do
  [[ "$source" == */main.swift ]] || SOURCES+=("$source")
done
swiftc -sdk "$SDK" -module-cache-path "$OUT/ModuleCache" \
  -D STANDALONE_TESTS -parse-as-library "${SOURCES[@]}" \
  Tests/ImageHistoryTests/ImageHistoryTests.swift Tests/Standalone/HistoryTestRunner.swift \
  -o "$OUT/history-tests"
"$OUT/history-tests"
