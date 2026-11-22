#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Diagnostic: immutable PR20 plus PR21 patch; no changes to the shipping backend.
set -euo pipefail

tools_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$(mktemp -d "${TMPDIR:-/tmp}/mcp-http-link.XXXXXX")}
mkdir -p "$output"
output=$(cd "$output" && pwd)
evidence="$output/evidence"
work="$output/work"
mkdir "$evidence" "$work"
printf 'Evidence: %s\n' "$evidence"
outcome=setup_incomplete
original_status=not_run
mini_status=not_run
trap 'result=$?; printf "outcome=%s\noriginal_build_exit_code=%s\nmini_runner_exit_code=%s\nscript_exit_code=%s\n" "$outcome" "$original_status" "$mini_status" "$result" > "$evidence/summary.txt"' EXIT

[[ $(uname -s) == Darwin ]] || { printf 'Requires the macOS test host.\n' >&2; exit 64; }
for tool in git swift xcrun xcodebuild sw_vers python3 shasum; do
    command -v "$tool" >/dev/null || { printf 'Missing tool: %s\n' "$tool" >&2; exit 64; }
done
jobs=${SWIFT_BUILD_JOBS:-2}
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export GIT_TERMINAL_PROMPT=0
{
    date -u
    sw_vers
    uname -m
    xcode-select -p
    xcodebuild -version
    swift --version
    xcrun --sdk macosx --show-sdk-version
    sysctl -n hw.model hw.logicalcpu hw.memsize
    sysctl -n vm.loadavg
    printf 'build_backend=toolchain default (unchanged)\njobs=%s\nSDKROOT=%s\n' "$jobs" "$SDKROOT"
    git -C "$tools_root" rev-parse HEAD
} >"$evidence/host.txt" 2>&1
printf 'step\texit_code\n' >"$evidence/results.tsv"
record_step() {
    local name=$1
    shift
    local status
    if "$@" >"$evidence/$name.log" 2>&1; then status=0; else status=$?; fi
    printf '%s\t%s\n' "$name" "$status" >>"$evidence/results.tsv"
    printf '[%s] exit %s\n' "$name" "$status"
    if [[ $status -ne 0 ]]; then tail -n 90 "$evidence/$name.log"; fi
    return "$status"
}

repo=https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git
base=104386cb2aef22594c4854dafd71a12519a5ed16
pr20=2c4f9e540f879c1d6c88fbb294b965da38c0a066
pr21=748f0fb99ac9bdad0ae2ef73e128a6c4d7d8942a
checkout="$work/checkout"
record_step clone git clone --no-checkout "$repo" "$checkout"
record_step fetch git -C "$checkout" fetch --no-tags origin "$pr20" "$pr21"
record_step checkout git -C "$checkout" checkout --detach "$pr20"
[[ $(git -C "$checkout" rev-parse HEAD) == "$pr20" ]]
[[ $(git -C "$checkout" rev-parse "$pr21^") == "$base" ]]
git -C "$checkout" diff --binary "$base" "$pr21" >"$evidence/pr21.patch"
record_step apply-check git -C "$checkout" apply --index --check "$evidence/pr21.patch"
record_step apply git -C "$checkout" apply --index "$evidence/pr21.patch"
combined_tree=$(git -C "$checkout" write-tree)
[[ $combined_tree == 7c14af7c698c29cf4704eda1b2cb76dd1840ead9 ]]
{
    printf 'base=%s\npr20=%s\npr21=%s\n' "$base" "$pr20" "$pr21"
    printf 'combined_tree=%s\n' "$combined_tree"
    printf 'Combination is an intentional staged patch on detached PR20, not a published commit.\n'
    shasum -a 256 "$evidence/pr21.patch"
    git -C "$checkout" diff --cached --stat
} >"$evidence/source.txt"
fixture="$checkout/Tools/Conformance/SwiftFixture"
cp "$checkout/Package.resolved" "$evidence/expected-root.Package.resolved"
cp "$fixture/Package.resolved" "$evidence/expected-fixture.Package.resolved"
record_step resolve-root swift package --package-path "$checkout" resolve
record_step resolve-fixture swift package --package-path "$fixture" resolve
cp "$checkout/Package.resolved" "$evidence/root.Package.resolved"
cp "$fixture/Package.resolved" "$evidence/fixture.Package.resolved"
record_step graph python3 -I "$checkout/Scripts/check-release-graph.py" "$checkout/Package.resolved" "$fixture/Package.resolved"
# Compare the worktree to the intentionally combined index, not to PR20's old locks.
record_step lock-drift git -C "$checkout" diff --exit-code -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved

if record_step release-server swift build -c release -j "$jobs" --package-path "$fixture" --product SwiftConformanceServer -v; then
    original_status=0
else
    original_status=$?
fi
record_step collect-evidence python3 -I "$tools_root/Scripts/collect-http-link-evidence.py" \
    "$evidence/release-server.log" "$fixture/.build" "$evidence/link"
printf 'Link diagnostic and available symbol evidence:\n'
cat "$evidence/link/diagnostic.json"
if [[ -f "$evidence/link/symbols-relevant.txt" ]]; then tail -n 160 "$evidence/link/symbols-relevant.txt"; fi
cp "$checkout/Package.resolved" "$evidence/final-root.Package.resolved"
cp "$fixture/Package.resolved" "$evidence/final-fixture.Package.resolved"
if ! record_step final-lock-drift git -C "$checkout" diff --exit-code -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved; then
    outcome=dependency_drift_during_build
    exit 1
fi
if [[ $original_status -eq 0 ]]; then
    if binary_dir=$(swift build -c release --package-path "$fixture" --show-bin-path 2>"$evidence/bin-path.log") \
        && [[ -x "$binary_dir/SwiftConformanceServer" ]]; then
        printf '%s\n' "$binary_dir/SwiftConformanceServer" >"$evidence/binary.txt"
        outcome=combined_server_linked_runtime_unqualified
        printf 'Combined server linked. Runtime/release qualification remains separate.\n'
        exit 0
    fi
    outcome=build_reported_success_but_binary_unverified
    exit 1
fi

outcome=original_build_failed_without_matching_metadata
if python3 - "$evidence/link/diagnostic.json" <<'PY'
import json, pathlib, sys
raise SystemExit(0 if json.loads(pathlib.Path(sys.argv[1]).read_text())["matching_undefined_metadata"] else 1)
PY
then
    outcome=original_matching_link_failure
    mini="$tools_root/Tools/HTTPLinkReproducer/run.sh"
    if [[ -f "$mini" ]]; then
        mkdir "$work/minis"
        if record_step mini-runner bash "$mini" published swiftbuild "$work/minis"; then mini_status=0; else mini_status=$?; fi
        python3 - "$work/minis" "$evidence/minis" <<'PY'
import pathlib, shutil, sys
source, target = map(pathlib.Path, sys.argv[1:])
for run in source.iterdir():
    if (run / "evidence").is_dir():
        shutil.copytree(run / "evidence", target / run.name)
PY
    else
        mini_status=not_installed
        printf 'Matching original symbols found; optional mini-probe is not installed.\n' >"$evidence/mini-runner.log"
    fi
fi
printf 'Original server build remains failed. Mini-probe results are diagnostic, not a fix.\n'
exit 1
