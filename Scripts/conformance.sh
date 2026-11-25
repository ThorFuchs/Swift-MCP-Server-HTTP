#!/bin/bash
# Runs the official MCP conformance referee (server leg, requirements 2026-07-28) against the
# Swift conformance fixture over loopback HTTP.
# Usage: Scripts/conformance.sh [output-dir]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
configuration="${MCP_HTTP_FIXTURE_CONFIGURATION:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "Unsupported MCP_HTTP_FIXTURE_CONFIGURATION: $configuration" >&2; exit 64 ;;
esac
out="${1:-$root/.build/conformance/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
[[ -z "$(ls -A "$out")" ]] || { echo "Use a fresh server conformance output directory: $out" >&2; exit 1; }

# 1. Referee: the exact pinned version from package-lock.json, without install scripts.
(cd Tools/Conformance && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
referee="$root/Tools/Conformance/node_modules/.bin/conformance"

# 2. Fixture server.
swift build --force-resolved-versions -c "$configuration" -j "${SWIFT_BUILD_JOBS:-2}" --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceServer
fixture="$(swift build --force-resolved-versions -c "$configuration" -j "${SWIFT_BUILD_JOBS:-2}" --package-path Tools/Conformance/SwiftFixture --show-bin-path)/SwiftConformanceServer"

# 3. Start it on 127.0.0.1:0 and wait for its readiness record.
work="$(mktemp -d)"
nonce="conformance-$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')"
"$fixture" --host 127.0.0.1 --port 0 --ready-file "$work/ready.json" --nonce "$nonce" 2> "$out/fixture.stderr" &
pid=$!
cleanup() { kill -TERM "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT
for _ in $(seq 1 600); do
    [[ -s "$work/ready.json" ]] && break
    kill -0 "$pid" 2>/dev/null || { echo "fixture exited before readiness" >&2; cat "$out/fixture.stderr" >&2; exit 1; }
    sleep 0.1
done
[[ -s "$work/ready.json" ]] || { echo "fixture not ready after 60 s" >&2; exit 1; }
url="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["nonce"]==sys.argv[2]; print(d["url"])' "$work/ready.json" "$nonce")"
echo "fixture ready at $url"

# 4. Execute the frozen server requirements and separately gated Skills. The
# gate records each process exit, validates raw receipts against the exact
# scenario sets, and preserves warnings and the known upstream Tasks skip.
python3 -I "$root/Scripts/conformance_summary.py" "$root" "$referee" "$url" "$out"
