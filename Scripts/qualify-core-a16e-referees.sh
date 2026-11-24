#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# A1.6e B3: official referee matrix on the idle native macOS 27 host.
# This is not the HTTP release gate. No package edit, no dependency update.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$root"
core="02958abee82c363b879aa013c38229edb9a1c116"
nio="b003027fc38b649a43e9aad77c3d4e4a2c5b6997"
sqlite="df12fe55265de81e2fc4bca91cb85704343b528f"
expected="${1:?Pass the exact HTTP qualification commit SHA}"
output="${2:?Pass an absolute output directory outside this checkout}"
[[ "$output" == /* && "$expected" =~ ^[0-9a-f]{40}$ ]]
test "$(uname -s)" = Darwin
test "$(git rev-parse HEAD)" = "$expected"
test -z "$(git status --porcelain)"
mkdir -p "$output"
output="$(cd "$output" && pwd -P)"
case "$output/" in "$root/"*) echo "Output must be outside checkout" >&2; exit 64;; esac
out="$(mktemp -d "$output/core-a16e-b3-XXXXXXXX")"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export LC_ALL=C
lockpaths=(Package.swift Package.resolved Tools/Conformance/SwiftFixture/Package.swift Tools/Conformance/SwiftFixture/Package.resolved Tools/Conformance/package.json Tools/Conformance/package-lock.json Tools/Conformance/.nvmrc Tools/Conformance/.npmrc)
printf 'step\tstatus\n' > "$out/results.tsv"
{
    git rev-parse HEAD
    swift --version
    sw_vers
    uname -sm
    sysctl -n hw.ncpu
} > "$out/provenance.txt"
shasum -a 256 "${lockpaths[@]}" > "$out/before.sha256"
cp Package.resolved "$out/root.before.json"
cp Tools/Conformance/SwiftFixture/Package.resolved "$out/fixture.before.json"
cp Tools/Conformance/package-lock.json "$out/npm.before.json"
finish() {
    local rc=$?
    trap - EXIT
    set +e
    shasum -a 256 "${lockpaths[@]}" > "$out/after.sha256" || rc=1
    diff -u "$out/before.sha256" "$out/after.sha256" > "$out/dependency.diff" || rc=1
    git status --porcelain > "$out/git-status.txt" || rc=1
    [[ ! -s "$out/git-status.txt" && "$(git rev-parse HEAD)" == "$expected" ]] || rc=1
    cp Package.resolved "$out/root.after.json" || rc=1
    cp Tools/Conformance/SwiftFixture/Package.resolved "$out/fixture.after.json" || rc=1
    cp Tools/Conformance/package-lock.json "$out/npm.after.json" || rc=1
    printf 'exit_code=%s\n' "$rc" > "$out/summary.txt"
    if ! tar -czf "$out.tar.gz" -C "$out" .; then
        rc=1
        printf 'exit_code=%s\narchive_failed=1\n' "$rc" > "$out/summary.txt"
        echo "Archive failed; evidence directory retained: $out" >&2
    fi
    echo "Evidence: $out.tar.gz (exit $rc)"
    exit "$rc"
}
trap finish EXIT
run() {
    local label="$1"
    shift
    local rc=0
    "$@" > "$out/$label.log" 2>&1 || rc=$?
    printf '%s\t%s\n' "$label" "$rc" >> "$out/results.tsv"
    echo "$label: exit $rc"
    tail -n 12 "$out/$label.log"
    return "$rc"
}
run graph python3 -I - "$core" "$nio" "$sqlite" <<'PY'
import json, sys
from pathlib import Path
def pins(path):
    entries = json.loads(Path(path).read_text())["pins"]
    result = {p["identity"]: p["state"] for p in entries}
    if len(entries) != len(result):
        raise ValueError("duplicate pin")
    return result
root = pins("Package.resolved")
fixture = pins("Tools/Conformance/SwiftFixture/Package.resolved")
assert root == fixture, "root/fixture graph mismatch"
for k, rev in zip(("swift-mcp-server", "swift-nio", "swift-sqlite"), sys.argv[1:]):
    assert root[k]["revision"] == rev, (k, root[k])
assert root["swift-nio"]["version"] == "2.105.2"
assert root["swift-sqlite"]["version"] == "1.2.0"
print("Exact consumer graph:", root)
PY

# Toolchain preflight is captured even when Node or npm is unavailable.
run tools bash -c '
    set -euo pipefail
    test "$(uname -m)" = arm64
    test "$(sw_vers -productVersion | cut -d. -f1)" -ge 27
    swift --version | grep -E "Swift version 6\.4\.2([[:space:]]|$)"
    node --version
    npm --version
    test "$(node -p "process.versions.node.split(\".\")[0]")" = "$(cat Tools/Conformance/.nvmrc)"
    test "$(cat Tools/Conformance/.nvmrc)" = 24
    node -e "const p = require(\"./Tools/Conformance/package.json\"); const l = require(\"./Tools/Conformance/package-lock.json\"); if (p.devDependencies[\"@modelcontextprotocol/conformance\"] !== \"0.2.0-alpha.12\" || l.packages[\"node_modules/@modelcontextprotocol/conformance\"].version !== \"0.2.0-alpha.12\") process.exit(1)"
'
export MCP_STRICT_RESOLUTION=1
export SWIFT_BUILD_JOBS=2
# The existing referee legs retain their scenario selections and timeouts.
# Run them sequentially; their processes and output directories are independent.
failed=0
for mode in debug release; do
    export MCP_HTTP_FIXTURE_CONFIGURATION="$mode"
    for leg in server client; do
        label="$mode-$leg"
        script=Scripts/conformance.sh
        [[ "$leg" != client ]] || script=Scripts/client-conformance.sh
        mkdir -p "$out/$label"
        run "$label" bash "$script" "$out/$label" || failed=1
        run "$label-receipt" python3 -I Scripts/check-core-a16e-referee-receipts.py \
          "$leg" "$out/$label" "$out/$label.log" || failed=1
        if ! shasum -a 256 "${lockpaths[@]}" > "$out/$label.sha256" ||
           ! diff -u "$out/before.sha256" "$out/$label.sha256" > "$out/$label-dependency.diff"; then
            echo "Dependency drift after $label; remaining legs blocked" >&2
            exit 1
        fi
    done
done
exit "$failed"
