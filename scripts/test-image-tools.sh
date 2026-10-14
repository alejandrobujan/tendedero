#!/bin/bash
# macOS runs pixel operations too; Linux exercises the same production matcher.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s)" = "Darwin" ]; then
  swift test --build-system native
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  swiftc -swift-version 5 -O -module-cache-path "$WORK/cache" -D PORTABLE_TESTS \
    Sources/Tendedero/ImageGeometry.swift Tests/TendederoTests/ImageGeometryTests.swift \
    Tests/PortableRunner/main.swift -o "$WORK/image-tests"
  "$WORK/image-tests"
fi
