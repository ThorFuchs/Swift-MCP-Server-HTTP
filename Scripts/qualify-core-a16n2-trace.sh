#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# N2 diagnosis; same trace-capable binary with logging off/on, no release claim.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
self="$root/Scripts/qualify-core-a16n2-trace.sh"
checker="$root/Scripts/check-core-a16n-notifications.py"
trace_checker="$root/Scripts/check-core-a16n2-trace.py"
N1_CORE="044e2ab332d9f55632c900c13f23502acd8e8972"
TRACE_CORE="a2a4d3f3d11122c3e596a27277fe820b4ef2c647"
export LC_ALL=C

if [[ "${1:-}" == --case ]]; then
    fixture="$2"; referee="$3"; out="$4"; trace="$5"
    [[ "$trace" == 0 || "$trace" == 1 ]]
    mkdir -p "$out"
    nonce="conformance-$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')"
    MCP_A16N_TRACE="$trace" "$fixture" --host 127.0.0.1 --port 0 --ready-file "$out/ready.json" --nonce "$nonce" \
        > "$out/fixture.stdout" 2> "$out/fixture.stderr" &
    pid=$!
    cleanup() {
        local rc=$? child_rc=0
        trap - EXIT
        kill -TERM "$pid" 2>/dev/null || true
        wait "$pid" || child_rc=$?
        printf 'referee_or_setup_exit=%s\nfixture_exit=%s\n' "$rc" "$child_rc" > "$out/exit.txt"
        [[ $rc -ne 0 || $child_rc -eq 0 ]] || rc=1
        exit "$rc"
    }
    trap cleanup EXIT
    for _ in $(seq 1 600); do
        [[ -s "$out/ready.json" ]] && break
        kill -0 "$pid"
        sleep 0.1
    done
    test -s "$out/ready.json"
    url="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["nonce"]==sys.argv[2]; print(d["url"])' "$out/ready.json" "$nonce")"
    "$referee" server --url "$url" --scenario server-stateless --spec-version 2026-07-28 \
        --output-dir "$out/results" --timeout 90000 > "$out/referee.stdout" 2> "$out/referee.stderr"
    exit 0
fi

if [[ "${1:-}" == --arm ]]; then
    sha="$2"; checkout="$3"; out="$4"; source_sha="$5"
    mkdir -p "$out"
    git clone --no-hardlinks --no-checkout "$root" "$checkout" > "$out/clone.log" 2>&1
    cd "$checkout"
    git checkout --detach "$source_sha"
    test -z "$(git status --porcelain)"
    python3 -I "$checker" seed "$sha" "$out"
    git diff -- Package.swift Tools/Conformance/SwiftFixture/Package.swift > "$out/manifest.diff"
    # A native resolve is allowed ONLY for these explicit disposable revisions.
    # Check every non-Core pin and both checked-out commits before building.
    swift package resolve > "$out/resolve-root.log" 2>&1
    swift package --package-path Tools/Conformance/SwiftFixture resolve > "$out/resolve-fixture.log" 2>&1
    python3 -I "$checker" verify "$out"
    inputs=(Package.swift Package.resolved Tools/Conformance/SwiftFixture/Package.swift
        Tools/Conformance/SwiftFixture/Package.resolved Tools/Conformance/package.json
        Tools/Conformance/package-lock.json Tools/Conformance/.nvmrc Tools/Conformance/.npmrc)
    shasum -a 256 "${inputs[@]}" > "$out/before.sha256"
    (cd Tools/Conformance && npm ci --ignore-scripts --no-audit --no-fund --loglevel=error) > "$out/npm.log" 2>&1
    test "$(node -p 'require("./Tools/Conformance/node_modules/@modelcontextprotocol/conformance/package.json").version')" = 0.2.0-alpha.12
    referee="$checkout/Tools/Conformance/node_modules/.bin/conformance"
    python3 -I "$trace_checker" source "$checkout/Tools/Conformance/node_modules/@modelcontextprotocol/conformance" "$out/referee-source"
    failed=0
    for mode in debug release; do
        swift build --force-resolved-versions -c "$mode" -j 2 \
            --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceServer \
            > "$out/build-$mode.log" 2>&1
        bin="$(swift build --force-resolved-versions -c "$mode" -j 2 \
            --package-path Tools/Conformance/SwiftFixture --show-bin-path)/SwiftConformanceServer"
        test -x "$bin"
        shasum -a 256 "$bin" > "$out/$mode-fixture.sha256"
        legs=(debug-off debug-on1 debug-on2)
        [[ "$mode" != release ]] || legs=(release-on)
        for label in "${legs[@]}"; do
            leg="$out/$label"
            trace=1
            [[ "$label" != debug-off ]] || trace=0
            mkdir -p "$leg"
            rc=0; verify_rc=0; trace_rc=0
            bash "$self" --case "$bin" "$referee" "$leg" "$trace" || rc=$?
            # Diagnosis only: retain the original prompt SHOULD warning as
            # evidence. The N1 candidate acceptance gate remains unchanged.
            python3 -I "$checker" receipt baseline "$leg" > "$leg/receipt.log" 2>&1 || verify_rc=$?
            python3 -I "$trace_checker" trace "$leg" "$trace" > "$leg/trace.log" 2>&1 || trace_rc=$?
            printf '%s\t%s\t%s\t%s\n' "$label" "$rc" "$verify_rc" "$trace_rc" >> "$out/results.tsv"
            cat "$leg/receipt.log" "$leg/trace.log"
            [[ $rc -eq 0 && $verify_rc -eq 0 && $trace_rc -eq 0 ]] || failed=1
            shasum -a 256 "${inputs[@]}" > "$leg/after.sha256"
            diff -u "$out/before.sha256" "$leg/after.sha256" > "$leg/dependency.diff"
        done
    done
    python3 -I "$checker" verify "$out"
    git status --porcelain > "$out/status.txt"
    shasum -a 256 "${inputs[@]}" > "$out/after.sha256"
    diff -u "$out/before.sha256" "$out/after.sha256" > "$out/dependency.diff"
    exit "$failed"
fi

expected="${1:?Exact diagnostic runner SHA required}"
output="${2:?Absolute evidence directory required}"
[[ "$expected" =~ ^[0-9a-f]{40}$ && "$output" == /* ]]
test "$(git -C "$root" rev-parse HEAD)" = "$expected"
test -z "$(git -C "$root" status --porcelain)"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
case "$output/" in "$root/"*) exit 64;; esac
out="$(mktemp -d "$output/core-a16n2-trace-XXXXXXXX")"
scratch="$(mktemp -d "$output/core-a16n-work-XXXXXXXX")"
finish() {
    local rc=$?
    trap - EXIT
    set +e
    printf 'exit_code=%s\n' "$rc" > "$out/summary.txt"
    if ! tar -czf "$out.tar.gz" -C "$out" .; then
        rc=1
        printf 'exit_code=1\narchive_failed=1\n' > "$out/summary.txt"
    fi
    echo "ARCHIVE: $out.tar.gz (exit $rc)"
    echo "Disposable checkouts retained: $scratch"
    exit "$rc"
}
trap finish EXIT
{
    printf 'runner=%s\nn1_core=%s\ntrace_core=%s\n' "$expected" "$N1_CORE" "$TRACE_CORE"
    swift --version; sw_vers; uname -sm; sysctl -n hw.ncpu; node --version; npm --version
} > "$out/provenance.txt"
test "$(uname -sm)" = "Darwin arm64"
swift --version | grep -E 'Swift version 6\.4\.2([[:space:]]|$)'
test "$(node -p 'process.versions.node.split(".")[0]')" = 24
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
rc=0
bash "$self" --arm "$TRACE_CORE" "$scratch/trace" "$out/trace" "$expected" \
    > "$out/trace-arm.log" 2>&1 || rc=$?
printf 'trace\t%s\n' "$rc" > "$out/results.tsv"
tail -n 30 "$out/trace-arm.log"
exit "$rc"
