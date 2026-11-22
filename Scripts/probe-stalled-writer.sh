#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Diagnostic only: preserve the original test and report both configurations.
set -euo pipefail
probe_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$probe_root"
probe_output="${1:-$(mktemp -d "${TMPDIR:-/tmp}/mcp-stalled-probe.XXXXXX")}"
mkdir -p "$probe_output"
probe_output="$(cd "$probe_output" && pwd)"
printf 'Logs: %s\n' "$probe_output"
[[ "$(uname -s)" == Darwin ]] || { echo 'This probe requires the macOS test host.' >&2; exit 64; }
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
{
    git rev-parse HEAD
    sw_vers
    uname -m
    xcode-select -p
    xcodebuild -version
    swift --version
    xcrun --sdk macosx --show-sdk-version
    sysctl -n hw.model hw.logicalcpu hw.memsize
    sysctl -n vm.loadavg
} > "$probe_output/host.txt" 2>&1
cat "$probe_output/host.txt"
git diff --exit-code -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved
swift package resolve
swift package --package-path Tools/Conformance/SwiftFixture resolve
python3 -I Scripts/check-release-graph.py Package.resolved Tools/Conformance/SwiftFixture/Package.resolved | tee "$probe_output/dependencies.txt"
git diff --exit-code -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved
printf 'configuration\texit_code\ttrace_present\n' > "$probe_output/results.tsv"
probe_failed=0
for probe_configuration in debug release; do
    printf 'Running original stalled-writer test: %s\n' "$probe_configuration"
    set +e
    swift test -c "$probe_configuration" -j "${SWIFT_BUILD_JOBS:-2}" \
        --filter nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership \
        > "$probe_output/$probe_configuration.log" 2>&1
    probe_status=$?
    set -e
    probe_trace=0
    if grep -q '^STALLED_LIFECYCLE ' "$probe_output/$probe_configuration.log"; then
        probe_trace=1
    fi
    printf '%s\t%s\t%s\n' "$probe_configuration" "$probe_status" "$probe_trace" >> "$probe_output/results.tsv"
    tail -n 70 "$probe_output/$probe_configuration.log"
    if [[ "$probe_status" -ne 0 || "$probe_trace" -ne 1 ]]; then probe_failed=1; fi
done
git diff --exit-code -- Package.resolved Tools/Conformance/SwiftFixture/Package.resolved
cat "$probe_output/results.tsv"
exit "$probe_failed"
