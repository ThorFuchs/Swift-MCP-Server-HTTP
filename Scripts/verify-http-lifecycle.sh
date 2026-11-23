#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Run from a fresh, clean checkout; never cleans or changes the source revision.
# Usage: bash Scripts/verify-http-lifecycle.sh macbook|studio|ci focused|full EXPECTED_HTTP_SHA [output-root]
set -euo pipefail

machine="${1:-}"
mode="${2:-}"
expected="${3:-}"
case "$machine" in macbook|studio|ci) ;; *) echo "machine must be macbook, studio or ci" >&2; exit 64 ;; esac
case "$mode" in focused|full) ;; *) echo "mode must be focused or full" >&2; exit 64 ;; esac
[[ $# -ge 3 && $# -le 4 && "$expected" =~ ^[0-9a-f]{40}$ ]] || { echo "Supply a full, lowercase, 40-character expected commit SHA" >&2; exit 64; }
root="$(cd "$(dirname "$0")/.." && pwd -P)"
output_root="${4:-$HOME/MCP-Lifecycle}"
mkdir -p "$output_root"
output_root="$(cd "$output_root" && pwd -P)"
case "$output_root/" in "$root/"*) echo "output-root must be outside the checkout" >&2; exit 64 ;; esac
out="$(mktemp -d "$output_root/$machine-$mode-${expected:0:12}-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
mkdir -p "$out/logs" "$out/dependencies" "$out/referees"
results="$out/results.tsv"
printf 'step\tstatus\tcommand_exit\tverification_exit\tseconds\tdetail\n' > "$results"
printf 'machine=%s\nmode=%s\nexpected_sha=%s\nstarted_utc=%s\n' "$machine" "$mode" "$expected" "$(date -u +%FT%TZ)" > "$out/source.txt"
failed=0
blocked=0
current_step=""
last_ok=0

finish() {
    local exit_code=$? integrity=0 archive_exit=0
    trap - EXIT INT TERM HUP
    set +e
    if [[ -n "$current_step" ]]; then
        printf '%s\tINTERRUPTED\tunknown\t-\t-\tRunner exited with %s; see partial log\n' "$current_step" "$exit_code" >> "$results"
    fi
    git -C "$root" status --porcelain=v1 > "$out/git-status-after.txt" 2>&1 || integrity=1
    git -C "$root" diff HEAD -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved > "$out/dependency-drift.diff" 2>&1 || integrity=1
    [[ ! -s "$out/git-status-after.txt" && ! -s "$out/dependency-drift.diff" ]] || integrity=1
    [[ "$(git -C "$root" rev-parse --verify HEAD 2>/dev/null)" == "$expected" ]] || integrity=1
    for entry in root fixture; do
        local lock="$root/Package.resolved"
        [[ "$entry" == fixture ]] && lock="$root/Tools/Conformance/SwiftFixture/Package.resolved"
        [[ ! -f "$lock" ]] || cp "$lock" "$out/dependencies/$entry.after.json"
    done
    python3 -I - "$out/dependencies" > "$out/dependencies.txt" 2>&1 <<'PY'
import hashlib, json, pathlib, sys
for path in sorted(pathlib.Path(sys.argv[1]).glob('*.json')):
    data = path.read_bytes()
    print(f'{path.name} sha256={hashlib.sha256(data).hexdigest()}')
    for pin in sorted(json.loads(data)['pins'], key=lambda p: p['identity']):
        print(pin['identity'], json.dumps(pin['state'], sort_keys=True))
PY
    if [[ $integrity -ne 0 ]]; then
        failed=$((failed+1))
        printf 'final-source-integrity\tFAIL\t1\t-\t0\tCheckout or lockfiles differ from expected source\n' >> "$results"
        [[ $exit_code -ne 0 ]] || exit_code=1
    else
        printf 'final-source-integrity\tPASS\t0\t-\t0\tExpected source and committed locks unchanged\n' >> "$results"
    fi
    printf 'finished_utc=%s\nexit_code=%s\nfailed_steps=%s\nblocked_steps=%s\n' "$(date -u +%FT%TZ)" "$exit_code" "$failed" "$blocked" > "$out/summary.txt"
    # The archive is a sibling, so it cannot include itself. SIGKILL/power loss
    # cannot run traps; the directory still contains all logs written so far.
    tar -czf "$out.tar.gz" -C "$out" . || archive_exit=$?
    if [[ $archive_exit -ne 0 ]]; then
        echo "Archive failed ($archive_exit); partial files remain in $out" >&2
        [[ $exit_code -ne 0 ]] || exit_code=1
        printf 'finished_utc=%s\nexit_code=%s\nfailed_steps=%s\nblocked_steps=%s\narchive_exit_code=%s\n' "$(date -u +%FT%TZ)" "$exit_code" "$failed" "$blocked" "$archive_exit" > "$out/summary.txt"
    fi
    printf '\nResults: %s\nEvidence directory: %s\nArchive: %s\nExit: %s\n' "$results" "$out" "$out.tar.gz" "$exit_code"
    exit "$exit_code"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

verify_log() {
    python3 -I - "$1" "$2" <<'PY'
import pathlib, re, sys
kind, path = sys.argv[1:]
text = pathlib.Path(path).read_text(errors='replace')
def successful_counts(section):
    # SwiftBuild can launch one Swift Testing runner per test target. Targets
    # outside a filter may report zero tests; aggregate only actual execution.
    return [int(n) for n in re.findall(r'Test run with (\d+) tests?(?: in [^\n]*?)? passed', section)]
summaries = successful_counts(text)
if kind == 'focused':
    names = ('nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership',
             'nativeHTTPStalledWriterCancelsLiveProviderAndRecovers',
             'normalProviderReturnKeepsRequestOwnedUntilFailedEventDrainJoins',
             'nativeHTTPConnectionCeilingRejectsOvershootAndRecovers')
    assert sum(summaries) == 4, f'Expected exactly four executed Swift Testing tests, saw {summaries}'
    for name in names:
        assert len(re.findall(r'Test ' + re.escape(name) + r'\(\) passed', text)) == 1, f'Expected one successful execution of: {name}'
elif kind == 'suite':
    assert sum(summaries) > 0, 'No nonempty successful Swift Testing suite'
elif kind == 'qualification':
    sdk_marker = 'Run optimized HTTP SDK tests'
    fixture_marker = 'Run optimized fixture tests'
    assert text.count(sdk_marker) == 1 and text.count(fixture_marker) == 1, 'Missing qualification phase markers'
    sdk_start, fixture_start = text.index(sdk_marker), text.index(fixture_marker)
    assert sdk_start < fixture_start, 'Unexpected qualification phase order'
    sdk_counts = successful_counts(text[sdk_start + len(sdk_marker):fixture_start])
    fixture_counts = successful_counts(text[fixture_start + len(fixture_marker):])
    assert sum(sdk_counts) > 0, f'No executed optimized SDK tests: {sdk_counts}'
    assert sum(fixture_counts) > 0, f'No executed optimized fixture tests: {fixture_counts}'
elif kind == 'server-referee':
    match = re.search(r'required scenarios: (\d+)/(\d+) passed', text)
    assert match and int(match[1]) == int(match[2]) > 0, 'Missing nonempty server referee result'
elif kind == 'client-referee':
    matches = re.findall(r'^ok\s+.+?:\s*Passed:\s*(\d+)/(\d+),\s*0 failed', text, re.M)
    assert matches and all(int(a) == int(b) > 0 for a, b in matches), 'Missing or empty client referee result'
else:
    raise AssertionError(f'Unknown verification: {kind}')
print(f'Nonempty execution verified: {kind}')
PY
}

step() {
    local name="$1" verification="$2" command_exit=0 verification_exit=0 started=$SECONDS
    shift 2
    current_step="$name"
    printf '[%s] %s ... ' "$machine" "$name"
    { printf 'Command:'; printf ' %q' "$@"; printf '\n'; } > "$out/logs/$name.log"
    set +e
    (set -e; cd "$root"; "$@") >> "$out/logs/$name.log" 2>&1
    command_exit=$?
    set -e
    if [[ $command_exit -eq 0 && "$verification" != none ]]; then
        verify_log "$verification" "$out/logs/$name.log" >> "$out/logs/$name.log" 2>&1 || verification_exit=$?
    fi
    last_ok=0
    if [[ $command_exit -eq 0 && $verification_exit -eq 0 ]]; then
        last_ok=1
        printf '%s\tPASS\t%s\t%s\t%s\tlogs/%s.log\n' "$name" "$command_exit" "$verification_exit" "$((SECONDS-started))" "$name" >> "$results"
        echo PASS
    else
        failed=$((failed+1))
        printf '%s\tFAIL\t%s\t%s\t%s\tlogs/%s.log\n' "$name" "$command_exit" "$verification_exit" "$((SECONDS-started))" "$name" >> "$results"
        printf 'FAIL (command=%s verification=%s)\n' "$command_exit" "$verification_exit"
        tail -n 15 "$out/logs/$name.log"
    fi
    current_step=""
}

block() {
    blocked=$((blocked+1))
    printf '%s\tBLOCKED\t-\t-\t0\t%s\n' "$1" "$2" >> "$results"
    printf '[%s] %s ... BLOCKED: %s\n' "$machine" "$1" "$2"
}

preflight() {
    {
        date -u; uname -sm; hostname
        sw_vers || true
        sysctl hw.model hw.ncpu hw.memsize || true
        xcode-select -p || true
        xcodebuild -version || true
        swift --version || true
        xcrun --sdk macosx --show-sdk-version || true
        uptime; df -h "$root"
    } > "$out/host.txt" 2>&1
    local tool actual major
    for tool in git swift xcrun xcodebuild sw_vers python3 tar; do
        command -v "$tool" >/dev/null || { echo "Missing required tool: $tool"; return 1; }
    done
    [[ "$(uname -s)" == Darwin ]] || { echo "This runner qualifies native macOS HTTP behavior"; return 1; }
    major="$(sw_vers -productVersion)"; major="${major%%.*}"
    [[ "$major" -ge 27 ]] || { echo "macOS 27 or newer is required"; return 1; }
    actual="$(git rev-parse --verify HEAD)"
    printf 'actual_sha=%s\n' "$actual" >> "$out/source.txt"
    [[ "$actual" == "$expected" ]] || { echo "Unexpected source: $actual"; return 1; }
    git status --porcelain=v1 > "$out/git-status-before.txt"
    [[ ! -s "$out/git-status-before.txt" ]] || { echo "Checkout must be clean, including untracked files"; return 1; }
    [[ ! -e .build && ! -e Tools/Conformance/SwiftFixture/.build ]] || { echo "Use a fresh clone: a build directory already exists"; return 1; }
    cp Package.resolved "$out/dependencies/root.before.json"
    cp Tools/Conformance/SwiftFixture/Package.resolved "$out/dependencies/fixture.before.json"
}

locked_graph() {
    python3 -I Scripts/check-release-graph.py Package.resolved Tools/Conformance/SwiftFixture/Package.resolved
    git diff --exit-code HEAD -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved
}

referee_tools() {
    command -v node || { echo "Missing required tool: node"; return 1; }
    command -v npm || { echo "Missing required tool: npm"; return 1; }
    node --version; npm --version
    [[ "$(node -p 'process.versions.node.split(".")[0]')" == "$(cat Tools/Conformance/.nvmrc)" ]] || { echo "Select the Node major pinned by Tools/Conformance/.nvmrc"; return 1; }
}

step preflight none preflight
if [[ $last_ok -ne 1 ]]; then
    block remaining "Preflight failed; no builds or dependency resolution attempted"
    exit 1
fi
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SDKROOT
export SWIFT_BUILD_JOBS=2
step resolve-root none swift package resolve
root_resolved=$last_ok
step resolve-fixture none swift package --package-path Tools/Conformance/SwiftFixture resolve
fixture_resolved=$last_ok
if [[ $root_resolved -ne 1 || $fixture_resolved -ne 1 ]]; then
    block remaining "Dependency resolution failed; no tests attempted"
    exit 1
fi
step locked-graph none locked_graph
if [[ $last_ok -ne 1 ]]; then
    block remaining "Dependency graph failed or committed locks drifted; no tests attempted"
    exit 1
fi
focus='nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership|nativeHTTPStalledWriterCancelsLiveProviderAndRecovers|normalProviderReturnKeepsRequestOwnedUntilFailedEventDrainJoins|nativeHTTPConnectionCeilingRejectsOvershootAndRecovers'
step focused-debug focused swift test -c debug -j 2 --filter "$focus"
debug_ok=$last_ok
step focused-release focused swift test -c release -j 2 --filter "$focus"
release_ok=$last_ok

if [[ "$mode" == full ]]; then
    prerequisites=0
    if [[ $debug_ok -eq 1 && $release_ok -eq 1 ]]; then
        step referee-tools none referee_tools
        if [[ $last_ok -eq 1 ]]; then
            step sdk-debug suite bash Scripts/test.sh -j 2
            if [[ $last_ok -eq 1 ]]; then
                step qualify-release qualification bash Scripts/qualify-release.sh full
                prerequisites=$last_ok
            else
                block qualify-release "Full debug suite failed"
            fi
        else
            block sdk-debug "Node/npm prerequisites failed"
            block qualify-release "Node/npm prerequisites failed"
        fi
    else
        block sdk-debug "Focused debug/release checks failed"
        block qualify-release "Focused debug/release checks failed"
    fi
    for configuration in debug release; do
        for side in server client; do
            name="referee-$configuration-$side"
            if [[ $prerequisites -eq 1 ]]; then
                script=Scripts/conformance.sh
                [[ "$side" == server ]] || script=Scripts/client-conformance.sh
                step "$name" "$side-referee" env "MCP_HTTP_FIXTURE_CONFIGURATION=$configuration" bash "$script" "$out/referees/$configuration-$side"
            else
                block "$name" "Full debug tests and release qualification must both pass first"
            fi
        done
    done
fi
[[ $failed -eq 0 && $blocked -eq 0 ]]
