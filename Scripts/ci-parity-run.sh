#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Isolated macOS 27 runner parity: pinned source SHA, fresh clone, full evidence.
# Usage: bash Scripts/ci-parity-run.sh {baseline|pr20|pr21} {macbook|studio} [focused|full] [output-root]
set -euo pipefail

snapshot="${1:-}"
machine="${2:-}"
mode="${3:-focused}"
output_root="${4:-$HOME/MCP-CI-Parity}"
case "$snapshot" in
  baseline) source_sha="104386cb2aef22594c4854dafd71a12519a5ed16"; fetch_ref="" ;;
  pr20) source_sha="2c4f9e540f879c1d6c88fbb294b965da38c0a066"; fetch_ref="refs/pull/20/head" ;;
  pr21) source_sha="748f0fb99ac9bdad0ae2ef73e128a6c4d7d8942a"; fetch_ref="refs/pull/21/head" ;;
  *) echo "Usage: $0 {baseline|pr20|pr21} {macbook|studio} [focused|full] [output-root]" >&2; exit 64 ;;
esac
case "$machine" in macbook|studio) ;; *) echo "machine must be macbook or studio" >&2; exit 64 ;; esac
case "$mode" in focused|full) ;; *) echo "mode must be focused or full" >&2; exit 64 ;; esac
if [[ "$(uname -s)" != Darwin ]] || [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 27 ]]; then
  echo "Requires macOS 27 or later" >&2; exit 2
fi
for tool in git swift xcrun xcodebuild sw_vers python3 shasum tar; do
  command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 2; }
done
mkdir -p "$output_root"
run_dir="$(mktemp -d "$output_root/$machine-$snapshot-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")"
checkout="$run_dir/checkout"
logs="$run_dir/logs"
mkdir -p "$logs"
results="$run_dir/results.tsv"
printf 'step\texit_code\tlog\n' > "$results"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export SWIFT_BUILD_JOBS=2

{
  printf 'snapshot=%s\nmachine_label=%s\nmode=%s\nexpected_http_sha=%s\n' "$snapshot" "$machine" "$mode" "$source_sha"
  printf 'utc_time=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '\n== macOS ==\n'; sw_vers
  printf '\n== architecture / hardware model (no serials) ==\n'; uname -smr
  sysctl -n hw.model hw.ncpu hw.memsize 2>&1 || true
  printf '\n== selected Xcode / Swift ==\n'
  xcode-select -p 2>&1 || true
  xcodebuild -version 2>&1 || true
  command -v swift
  swift --version
  xcrun --find swift 2>&1 || true
  xcrun --sdk macosx --show-sdk-version 2>&1 || true
  printf 'SDKROOT=%s\n' "$SDKROOT"
  printf '\n== load and free disk ==\n'; sysctl -n vm.loadavg 2>&1 || true
  df -h "$output_root" 2>&1 || true
} > "$run_dir/host.txt"

echo "Creating fresh checkout: $checkout"
git clone --quiet https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git "$checkout"
if [[ -n "$fetch_ref" ]]; then git -C "$checkout" fetch --quiet origin "$fetch_ref"; fi
git -C "$checkout" checkout --quiet --detach "$source_sha"
actual_sha="$(git -C "$checkout" rev-parse --verify HEAD)"
[[ "$actual_sha" == "$source_sha" ]] || { echo "Source SHA mismatch" >&2; exit 3; }
[[ -z "$(git -C "$checkout" status --porcelain)" ]] || { echo "Fresh checkout is not clean" >&2; exit 3; }
printf 'expected_sha=%s\nactual_sha=%s\n' "$source_sha" "$actual_sha" > "$run_dir/source.txt"

failed_steps=0
record_step() {
  local name="$1"; shift
  local status=0
  printf '[%s] %s ... ' "$snapshot" "$name"
  (cd "$checkout" && "$@") > "$logs/$name.log" 2>&1 || status=$?
  printf '%s\n' "$([[ "$status" -eq 0 ]] && echo PASS || echo FAIL:$status)"
  printf '%s\t%d\t%s\n' "$name" "$status" "logs/$name.log" >> "$results"
  if [[ "$status" -ne 0 ]]; then
    failed_steps=$((failed_steps + 1))
    tail -n 12 "$logs/$name.log" || true
  fi
}
record_step resolve-root swift package resolve
record_step resolve-fixture swift package --package-path Tools/Conformance/SwiftFixture resolve
record_step graph-consistency python3 -I Scripts/check-release-graph.py Package.resolved Tools/Conformance/SwiftFixture/Package.resolved

record_step build-debug swift build -c debug -j 2
record_step build-release swift build -c release -j 2
record_step link-release-server swift build -c release -j 2 --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceServer
record_step link-release-client swift build -c release -j 2 --package-path Tools/Conformance/SwiftFixture --product SwiftConformanceClient
for config in debug release; do
  for iteration in 1 2 3; do
    record_step "$config-stalled-$iteration" swift test -c "$config" -j 2 --filter nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership
    record_step "$config-ceiling-$iteration" swift test -c "$config" -j 2 --filter nativeHTTPConnectionCeilingRejectsOvershootAndRecovers
  done
done

if [[ "$mode" == full ]]; then
  record_step suite-debug bash Scripts/test.sh
  record_step suite-release swift test -c release -j 2
  record_step fixture-tests-release swift test -c release -j 2 --package-path Tools/Conformance/SwiftFixture
  record_step referee-server-debug env MCP_HTTP_FIXTURE_CONFIGURATION=debug bash Scripts/conformance.sh "$logs/referee-server-debug"
  record_step referee-client-debug env MCP_HTTP_FIXTURE_CONFIGURATION=debug bash Scripts/client-conformance.sh "$logs/referee-client-debug"
  record_step referee-server-release env MCP_HTTP_FIXTURE_CONFIGURATION=release bash Scripts/conformance.sh "$logs/referee-server-release"
  record_step referee-client-release env MCP_HTTP_FIXTURE_CONFIGURATION=release bash Scripts/client-conformance.sh "$logs/referee-client-release"
fi

{
  printf '== HTTP source SHA ==\n%s\n' "$actual_sha"
  python3 -I - "$checkout/Package.resolved" "$checkout/Tools/Conformance/SwiftFixture/Package.resolved" <<'PY'
import json, sys
wanted = {'swift-mcp-server', 'swift-http-server', 'swift-nio', 'swift-json', 'swift-collections'}
for index, path in enumerate(sys.argv[1:]):
    print('[HTTP root]' if index == 0 else '[Conformance fixture]')
    with open(path, encoding='utf-8') as file:
        for item in json.load(file)['pins']:
            if item['identity'] in wanted:
                state = item['state']
                print(f"{item['identity']}: {state.get('revision')} / {state.get('version', state.get('branch', 'unknown'))}")
PY
  printf '\n== actual Package.resolved SHA256 ==\n'
  shasum -a 256 "$checkout/Package.resolved" "$checkout/Tools/Conformance/SwiftFixture/Package.resolved"
} > "$run_dir/dependencies.txt" 2>&1

git -C "$checkout" diff -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved > "$run_dir/dependency-drift.diff"
if [[ -s "$run_dir/dependency-drift.diff" ]]; then
  printf 'dependency_drift=YES\n' >> "$run_dir/source.txt"
  printf 'WARNING: SwiftPM moved committed dependency pins. Cross-host comparison requires matching effective pins.\n'
  failed_steps=$((failed_steps + 1))
else
  printf 'dependency_drift=NO\n' >> "$run_dir/source.txt"
fi
git -C "$checkout" status --short > "$run_dir/worktree-status.txt"
(grep -H "STALLED_WRITER" "$logs"/{debug,release}-stalled-*.log || true) > "$run_dir/stalled-traces.txt"
tar -czf "$run_dir/report.tar.gz" -C "$run_dir" host.txt source.txt dependencies.txt dependency-drift.diff worktree-status.txt stalled-traces.txt results.tsv logs
printf '\nResults: %s\nStalled traces: %s\nReport: %s\nFailures/drift: %s\n' "$results" "$run_dir/stalled-traces.txt" "$run_dir/report.tar.gz" "$failed_steps"
if [[ "$failed_steps" -gt 0 ]]; then exit 1; fi
