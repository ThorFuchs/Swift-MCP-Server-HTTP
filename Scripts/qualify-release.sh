#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Usage: bash Scripts/qualify-release.sh [full|build-only]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mode="${1:-full}"
case "$mode" in
  full|build-only) ;;
  *) echo "usage: $0 [full|build-only]" >&2; exit 64 ;;
esac
jobs="${SWIFT_BUILD_JOBS:-2}"
if [[ "$(uname -s)" == "Darwin" ]]; then
  export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
fi
echo "Release qualification mode=$mode, jobs=$jobs"
echo "Source: $(git rev-parse HEAD)"
swift --version
echo "Resolve package and fixture dependency graphs"
swift package resolve
swift package --package-path Tools/Conformance/SwiftFixture resolve
python3 -I Scripts/check-release-graph.py Package.resolved Tools/Conformance/SwiftFixture/Package.resolved
echo "Optimize all HTTP library products"
swift build -c release -j "$jobs"
echo "Link optimized server fixture"
swift build -c release -j "$jobs" --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceServer
echo "Link optimized client fixture"
swift build -c release -j "$jobs" --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceClient
if [[ "$mode" == "full" ]]; then
  echo "Run optimized HTTP SDK tests"
  swift test -c release -j "$jobs"
  echo "Run optimized fixture tests"
  swift test -c release -j "$jobs" --package-path Tools/Conformance/SwiftFixture
fi
echo "Release qualification $mode passed at $(git rev-parse HEAD)"
