#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# HTTP #12 diagnostic only: exercise the accepted Apple SwiftNIO merge without
# publishing a revision dependency, vendor patch, or relaxing test assertions.
# Usage: MCP_NIO_PROOF_MODE=focused|full bash Scripts/qualify-swiftnio-upstream-eof.sh
set -euo pipefail

readonly NIO_SHA="a7d4e6b50c9be24d3a55f1a50e6e52bfc1d683d5"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="${MCP_NIO_PROOF_OUT_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nio-upstream-eof-proof}"
mode="${MCP_NIO_PROOF_MODE:-focused}"
case "$mode" in focused|full) ;; *) echo "Expected MCP_NIO_PROOF_MODE=focused or full" >&2; exit 64 ;; esac
mkdir -p "$out"
exec > >(tee "$out/driver.log") 2>&1

if [[ "$(uname -s)" != "Darwin" ]] || [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 27 ]]; then
  echo "HTTP #12 requires a real macOS 27+ host" >&2
  exit 2
fi
swift --version | tee "$out/swift-version.txt"
grep -F 'Swift version 6.4.2' "$out/swift-version.txt" >/dev/null || {
  echo "Unexpected Swift toolchain; this diagnostic pins Swift 6.4.2" >&2; exit 2;
}
source_sha="$(git -C "$root" rev-parse --verify HEAD)"
if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "Source checkout is not clean; refusing an ambiguous comparison" >&2
  exit 2
fi
{
  echo "http_source_sha=$source_sha"
  echo "nio_upstream_merge_sha=$NIO_SHA"
  echo "mode=$mode"
  sw_vers
  uname -sm
  xcodebuild -version
  swift --version
} | tee "$out/provenance.txt"
cp "$root/Package.resolved" "$out/root-lock-before.json"
cp "$root/Tools/Conformance/SwiftFixture/Package.resolved" "$out/fixture-lock-before.json"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/nio-upstream-eof.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/http" "$scratch/swift-nio"
# Fetch the exact triggering Git commit into an independent, disposable source tree.
git -C "$scratch/http" init -q
git -C "$scratch/http" fetch -q --no-tags --depth 1 "$root" "$source_sha"
git -C "$scratch/http" checkout -q --detach FETCH_HEAD
test "$(git -C "$scratch/http" rev-parse HEAD)" = "$source_sha"
git -C "$scratch/swift-nio" init -q
git -C "$scratch/swift-nio" remote add origin https://github.com/apple/swift-nio.git
git -C "$scratch/swift-nio" fetch -q --no-tags --depth 1 origin "$NIO_SHA"
git -C "$scratch/swift-nio" checkout -q --detach FETCH_HEAD
test "$(git -C "$scratch/swift-nio" rev-parse HEAD)" = "$NIO_SHA"
echo "Verified upstream Apple SwiftNIO merge $NIO_SHA"

# The production test file remains untouched; enforce exactly three local removals.
python3 - "$scratch/http/Tests/MCPHTTPTests/NativeListenerTests.swift" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
needle = "await withKnownIssue(macOSEarlyEOFKnownIssue) {"
cases = (
    "nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion",
    "nativeHTTPRepeatedFINReleasesOwnersAndRecovers",
    "nativeTLSPeerProcessExitCancelsBeforeResponseHead",
)
if source.count(needle) != len(cases):
    raise SystemExit(f"Expected exactly {len(cases)} early-EOF masks; found {source.count(needle)}")
for name in cases:
    marker = f"@Test func {name}()"
    if source.count(marker) != 1:
        raise SystemExit(f"Expected one named test {name}; found {source.count(marker)}")
    start = source.index(marker)
    end = source.find("@Test func ", start + len(marker))
    body = source[start:end if end != -1 else len(source)]
    if body.count(needle) != 1:
        raise SystemExit(f"Expected one known-issue mask inside {name}; found {body.count(needle)}")
source = source.replace(needle, "do {")
if needle in source:
    raise SystemExit("A known-issue mask remains")
path.write_text(source, encoding="utf-8")
print("Unmasked exactly three named tests in disposable checkout; assertions unchanged")
PY
cd "$scratch/http"
git diff -- Tests/MCPHTTPTests/NativeListenerTests.swift | tee "$out/unmask.patch"
test "$(git diff --name-only)" = "Tests/MCPHTTPTests/NativeListenerTests.swift"

# Both independent SwiftPM workspaces must compile the SAME upstream source.
swift package resolve 2>&1 | tee "$out/resolve-root.log"
swift package edit swift-nio --path "$scratch/swift-nio" 2>&1 | tee "$out/edit-root.log"
swift package --package-path Tools/Conformance/SwiftFixture resolve 2>&1 | tee "$out/resolve-fixture.log"
swift package --package-path Tools/Conformance/SwiftFixture edit swift-nio --path "$scratch/swift-nio" 2>&1 | tee "$out/edit-fixture.log"
swift package show-dependencies --format json > "$out/deps-root.json"
swift package --package-path Tools/Conformance/SwiftFixture show-dependencies --format json > "$out/deps-fixture.json"

# Keep every other resolved dependency identical to the baseline (including Core).
python3 - "$out" "$scratch/swift-nio" <<'PY'
import json
from pathlib import Path
import sys
out, nio = Path(sys.argv[1]), Path(sys.argv[2]).resolve()
for prefix in ("root", "fixture"):
    before = {x["identity"]: x["state"] for x in json.loads((out / f"{prefix}-lock-before.json").read_text())["pins"]}
    after_path = Path("Package.resolved" if prefix == "root" else "Tools/Conformance/SwiftFixture/Package.resolved")
    after = {x["identity"]: x["state"] for x in json.loads(after_path.read_text())["pins"]}
    changes = [(key, before.get(key), after.get(key)) for key in sorted(set(before) | set(after)) if key != "swift-nio" and before.get(key) != after.get(key)]
    if changes:
        raise SystemExit(f"{prefix} unrelated SwiftPM pin drift: {changes}")
    deps = (out / f"deps-{prefix}.json").read_text()
    if str(nio) not in deps and str(nio).replace("/private/var/", "/var/") not in deps:
        raise SystemExit(f"{prefix} graph does not show the edited SwiftNIO checkout {nio}")
    print(f"{prefix} graph uses exact local upstream checkout; no unrelated pin drift")
PY

printf 'configuration\ttest\tstatus\n' > "$out/focused.tsv"
for configuration in debug release; do
  for case_name in \
    nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion \
    nativeHTTPRepeatedFINReleasesOwnersAndRecovers \
    nativeTLSPeerProcessExitCancelsBeforeResponseHead; do
    echo "=== $configuration / $case_name / Apple $NIO_SHA ==="
    log="$out/$configuration-$case_name.log"
    swift test -c "$configuration" -j 2 --filter "$case_name" 2>&1 | tee "$log"
    if ! grep -F "$case_name() passed" "$log" >/dev/null; then
      echo "FAIL: required named test did not report a pass; empty filters never count" >&2
      exit 1
    fi
    printf '%s\t%s\tPASS\n' "$configuration" "$case_name" >> "$out/focused.tsv"
  done
done

if [[ "$mode" == full ]]; then
  swift test -j 2 2>&1 | tee "$out/full-debug.log"
  SWIFT_BUILD_JOBS=2 bash Scripts/qualify-release.sh full 2>&1 | tee "$out/full-release.log"
  MCP_HTTP_FIXTURE_CONFIGURATION=release bash Scripts/conformance.sh "$out/server-referee" 2>&1 | tee "$out/server-referee.log"
  MCP_HTTP_FIXTURE_CONFIGURATION=release bash Scripts/client-conformance.sh "$out/client-referee" 2>&1 | tee "$out/client-referee.log"
fi

# Workspace edits may change only the two disposable lockfiles in addition to the test.
unexpected="$(git diff --name-only | grep -Ev '^(Tests/MCPHTTPTests/NativeListenerTests\.swift|Package\.resolved|Tools/Conformance/SwiftFixture/Package\.resolved)$' || true)"
if [[ -n "$unexpected" ]]; then
  echo "Unexpected tracked source changes in disposable checkout: $unexpected" >&2
  exit 1
fi
git diff --name-only | tee "$out/tracked-changes.txt"
echo "PASS: all selected HTTP #12 cases unmasked against exact Apple merge $NIO_SHA"
echo "DIAGNOSTIC ONLY: no published SwiftNIO release contains this proof source; no release gate is closed."
