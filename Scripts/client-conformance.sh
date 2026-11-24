#!/bin/bash
# Runs the official MCP conformance referee in client mode (requirements 2026-07-28) against the
# Swift client fixture. Every listed scenario must pass; authorization scenarios are added per
# slice of ADR-0006 as they land (A1-A5 so far).
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
# Preserve normal CI behavior; B3 opts into the exact locked fixture graph.
build_fixture() {
    if [[ "${MCP_STRICT_RESOLUTION:-0}" == 1 ]]; then
        swift build --force-resolved-versions "$@"
    else
        swift build "$@"
    fi
}
build_fixture -c "$configuration" -j "${SWIFT_BUILD_JOBS:-2}" --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceClient
client="$(build_fixture -c "$configuration" -j "${SWIFT_BUILD_JOBS:-2}" --package-path Tools/Conformance/SwiftFixture --show-bin-path)/SwiftConformanceClient"

if [[ "${MCP_STRICT_RESOLUTION:-0}" == 1 ]]; then
    test -x "$client"
    node -p 'require("./Tools/Conformance/node_modules/@modelcontextprotocol/conformance/package.json").version' > "$out/referee-version.txt"
    test "$(cat "$out/referee-version.txt")" = 0.2.0-alpha.12
    shasum -a 256 "$client" > "$out/fixture.sha256"
fi

scenarios=(tools_call request-metadata sep-2322-client-request-state http-standard-headers
    http-custom-headers http-invalid-tool-headers json-schema-ref-no-deref json-schema-2020-12-preservation
    sep-2640-client-no-prefetch sep-2640-client-verify-digest sep-2640-client-verify-size sep-2640-client-verify-frontmatter
    auth/metadata-default auth/metadata-var1 auth/metadata-var2 auth/metadata-var3 auth/metadata-issuer-mismatch
    auth/resource-mismatch auth/basic-cimd auth/pre-registration
    auth/token-endpoint-auth-basic auth/token-endpoint-auth-post auth/token-endpoint-auth-none
    auth/iss-supported auth/iss-not-advertised auth/iss-supported-missing auth/iss-wrong-issuer auth/iss-unexpected auth/iss-normalized
    auth/scope-from-www-authenticate auth/scope-from-scopes-supported auth/scope-omitted-when-undefined
    auth/scope-step-up auth/scope-retry-limit auth/offline-access-scope auth/offline-access-not-supported
    auth/authorization-server-migration)
failed=0
printf 'scenario\treferee_exit\n' > "$out/referee-exits.tsv"
for scenario in "${scenarios[@]}"; do
    # Extension scenarios (sep-*) are off the spec timeline; the referee runs them only with --force.
    force=(); [[ "$scenario" == sep-2640-* ]] && force=(--force)
    set +e
    "$referee" client --command "$client" --scenario "$scenario" --spec-version 2026-07-28 ${force[@]+"${force[@]}"} \
        --output-dir "$out/${scenario//\//-}" > "$out/${scenario//\//-}.log" 2>&1
    exit_code=$?
    set -e
    printf '%s\t%s\n' "$scenario" "$exit_code" >> "$out/referee-exits.tsv"
    summary="$(grep -E '^Passed:' "$out/${scenario//\//-}.log" | tail -1 || true)"
    if [[ $exit_code -ne 0 ]] || ! grep -qE '^Passed: [0-9]+/[0-9]+, 0 failed' <<< "$summary"; then
        echo "FAIL $scenario (exit $exit_code) ${summary:-no summary}"; failed=1
    else
        echo "ok   $scenario: $summary"
    fi
done
exit $failed
