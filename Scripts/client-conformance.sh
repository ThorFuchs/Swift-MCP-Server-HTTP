#!/bin/bash
# Runs the official MCP conformance referee in client mode (requirements 2026-07-28) against the
# Swift client fixture. The frozen Core requirement set plus explicitly gated supplements must pass.
# The Python gate validates raw checks and reports required/extra categories separately.
# Usage: Scripts/client-conformance.sh [output-dir]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
configuration="${MCP_HTTP_FIXTURE_CONFIGURATION:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "Unsupported MCP_HTTP_FIXTURE_CONFIGURATION: $configuration" >&2; exit 64 ;;
esac
out="${1:-$root/.build/client-conformance/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
(cd Tools/Conformance && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
referee="$root/Tools/Conformance/node_modules/.bin/conformance"
swift build --force-resolved-versions -c "$configuration" -j "${SWIFT_BUILD_JOBS:-2}" --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceClient
client="$(swift build --force-resolved-versions -c "$configuration" -j "${SWIFT_BUILD_JOBS:-2}" --package-path Tools/Conformance/SwiftFixture --show-bin-path)/SwiftConformanceClient"

# The fixture checkout carries the frozen reference; independently verify its
# Git blob and actual Core revision before deriving the scenario selection.
python3 -I "$root/Scripts/client-conformance-gate.py" "$root" "$referee" "$client" "$out"
