#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Experimental, non-distributable qualification of our pinned SwiftNIO fork.
# Never used by release CI or a published package; workspace-only SwiftPM edit.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ "$(uname -s)" != "Darwin" ]] || [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 27 ]]; then
  echo "Early EOF qualification requires macOS 27+" >&2
  exit 2
fi
swift --version | tee /tmp/mcp-swift-nio-fork-toolchain.txt
grep -F 'Swift version 6.4.2' /tmp/mcp-swift-nio-fork-toolchain.txt
FORK_SHA="39107d50a7ee9f536d12c9396529db1b0825a8e0"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git init -q "$tmp/swift-nio"
git -C "$tmp/swift-nio" remote add origin https://github.com/ThorFuchs/swift-nio.git
git -C "$tmp/swift-nio" fetch -q --no-tags --depth 1 origin "$FORK_SHA"
git -C "$tmp/swift-nio" checkout -q --detach FETCH_HEAD
test "$(git -C "$tmp/swift-nio" rev-parse HEAD)" = "$FORK_SHA"
echo "Pinned downstream SwiftNIO: $FORK_SHA"
# Deliberate local checkout overrides for the TWO independent SwiftPM graphs.
# Never claim that a library's edit/mirror config is distributed to consumers.
swift package resolve
swift package edit swift-nio --path "$tmp/swift-nio"
swift package --package-path Tools/Conformance/SwiftFixture resolve
swift package --package-path Tools/Conformance/SwiftFixture edit swift-nio --path "$tmp/swift-nio"
# Strengthen, do not loosen, the three tracked tests in this isolated
# CI checkout: remove exact known-issue wrappers to make every failure fatal.
python3 - <<'PY'
from pathlib import Path
path = Path("Tests/MCPHTTPTests/NativeListenerTests.swift")
source = path.read_text()
pattern = "await withKnownIssue(macOSEarlyEOFKnownIssue) {"
if source.count(pattern) != 3:
    raise SystemExit(f"expected exactly 3 early-EOF masks, found {source.count(pattern)}")
path.write_text(source.replace(pattern, "do {"))
print("Removed exactly three early-EOF known-issue wrappers from CI checkout")
PY
for t in     nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion     nativeHTTPRepeatedFINReleasesOwnersAndRecovers     nativeTLSPeerProcessExitCancelsBeforeResponseHead
do
  echo "Qualifying unmasked test: $t"
  swift test --filter "$t" 2>&1 | tee "$tmp/$t.log"
  grep -F "$t() passed" "$tmp/$t.log"
done
echo "All three tracked early-EOF tests passed without masking on fork $FORK_SHA"
