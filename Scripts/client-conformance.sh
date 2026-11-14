#!/bin/bash
# Runs the official MCP conformance referee in client mode (requirements 2026-07-28, scenarios
# without authorization) against the Swift client fixture. Every scenario must pass.
# Usage: Scripts/client-conformance.sh [output-dir]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
out="${1:-$root/.build/client-conformance/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$out"
(cd Tools/Conformance && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error)
referee="$root/Tools/Conformance/node_modules/.bin/conformance"
swift build --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceClient
client="$(swift build --package-path Tools/Conformance/SwiftFixture --show-bin-path)/SwiftConformanceClient"

scenarios=(tools_call request-metadata sep-2322-client-request-state http-standard-headers
    http-custom-headers http-invalid-tool-headers json-schema-ref-no-deref json-schema-2020-12-preservation
    sep-2640-client-no-prefetch sep-2640-client-verify-digest sep-2640-client-verify-size sep-2640-client-verify-frontmatter)
failed=0
for scenario in "${scenarios[@]}"; do
    # Extension scenarios (sep-*) are off the spec timeline; the referee runs them only with --force.
    force=(); [[ "$scenario" == sep-2640-* ]] && force=(--force)
    set +e
    "$referee" client --command "$client" --scenario "$scenario" --spec-version 2026-07-28 ${force[@]+"${force[@]}"} \
        --output-dir "$out/$scenario" > "$out/$scenario.log" 2>&1
    exit_code=$?
    set -e
    summary="$(grep -E '^Passed:' "$out/$scenario.log" | tail -1 || true)"
    if [[ $exit_code -ne 0 ]] || ! grep -qE '^Passed: [0-9]+/[0-9]+, 0 failed' <<< "$summary"; then
        echo "FAIL $scenario (exit $exit_code) ${summary:-no summary}"; failed=1
    else
        echo "ok   $scenario: $summary"
    fi
done
exit $failed
