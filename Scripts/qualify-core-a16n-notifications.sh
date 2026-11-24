#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Focused A/B only; both arms use the same official B3 fixture and referee.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
self="$root/Scripts/qualify-core-a16n-notifications.sh"
checker="$root/Scripts/check-core-a16n-notifications.py"
BASE_HTTP="c99b65a9ee7879187e6d67e9771b8daa30115502"
BASE_CORE="02958abee82c363b879aa013c38229edb9a1c116"
NEW_CORE="044e2ab332d9f55632c900c13f23502acd8e8972"
export LC_ALL=C

if [[ "${1:-}" == --case ]]; then
    fixture="$2"; referee="$3"; out="$4"
    mkdir -p "$out"
    nonce="conformance-$(uuidgen | tr -d '-' | tr 'A-Z' 'a-z')"
    "$fixture" --host 127.0.0.1 --port 0 --ready-file "$out/ready.json" --nonce "$nonce" \
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
    arm="$2"; sha="$3"; checkout="$4"; out="$5"
    mkdir -p "$out"
    git clone --no-hardlinks --no-checkout "$root" "$checkout" > "$out/clone.log" 2>&1
    cd "$checkout"
    git checkout --detach "$BASE_HTTP"
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
    failed=0
    for mode in debug release; do
        swift build --force-resolved-versions -c "$mode" -j 2 \
            --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceServer \
            > "$out/build-$mode.log" 2>&1
        bin="$(swift build --force-resolved-versions -c "$mode" -j 2 \
            --package-path Tools/Conformance/SwiftFixture --show-bin-path)/SwiftConformanceServer"
        test -x "$bin"
        shasum -a 256 "$bin" > "$out/$mode-fixture.sha256"
        rounds=3
        [[ "$mode" != release ]] || rounds=1
        for round in $(seq 1 "$rounds"); do
            leg="$out/$mode-$round"
            mkdir -p "$leg"
            rc=0; verify_rc=0
            bash "$self" --case "$bin" "$referee" "$leg" || rc=$?
            python3 -I "$checker" receipt "$arm" "$leg" > "$leg/receipt.log" 2>&1 || verify_rc=$?
            printf '%s\t%s\t%s\n' "$mode-$round" "$rc" "$verify_rc" >> "$out/results.tsv"
            cat "$leg/receipt.log"
            [[ $rc -eq 0 && $verify_rc -eq 0 ]] || failed=1
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
out="$(mktemp -d "$output/core-a16n-notifications-XXXXXXXX")"
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
    printf 'runner=%s\nhttp=%s\nbaseline=%s\ncandidate=%s\n' "$expected" "$BASE_HTTP" "$BASE_CORE" "$NEW_CORE"
    swift --version; sw_vers; uname -sm; sysctl -n hw.ncpu; node --version; npm --version
} > "$out/provenance.txt"
test "$(uname -sm)" = "Darwin arm64"
swift --version | grep -E 'Swift version 6\.4\.2([[:space:]]|$)'
test "$(node -p 'process.versions.node.split(".")[0]')" = 24
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
failed=0
for arm in baseline candidate; do
    sha="$BASE_CORE"
    [[ "$arm" != candidate ]] || sha="$NEW_CORE"
    rc=0
    bash "$self" --arm "$arm" "$sha" "$scratch/$arm" "$out/$arm" \
        > "$out/$arm.log" 2>&1 || rc=$?
    printf '%s\t%s\n' "$arm" "$rc" >> "$out/results.tsv"
    tail -n 20 "$out/$arm.log"
    [[ $rc -eq 0 ]] || failed=1
done
exit "$failed"
