#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# A1.6e: diagnostic consumer proof. Run on the idle native macOS 27 host.
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
out="$(mktemp -d "$output/core-a16e-http-XXXXXXXX")"
export SDKROOT="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
export LC_ALL=C
lockpaths=(Package.swift Package.resolved Tools/Conformance/SwiftFixture/Package.swift Tools/Conformance/SwiftFixture/Package.resolved)
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
    printf 'exit_code=%s\n' "$rc" > "$out/summary.txt"
    tar -czf "$out.tar.gz" -C "$out" . || rc=1
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
# Ordinary public HTTP client suites, OAuth integration, and the three
# previously masked native listener cases. Use explicit suite/case filters.
filter='HTTPClientTransportCases|AuthorizationRetry|OAuthClientCodeFlow|OAuthClientDiscoveryAndIdentity|OAuthClientScopesAndRefresh|OAuthClientLifecycle|WWWAuthenticateParsing|nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion|nativeHTTPRepeatedFINReleasesOwnersAndRecovers|nativeTLSPeerProcessExitCancelsBeforeResponseHead'
failed=0
for mode in debug release; do
    run "$mode-consumer" swift test --force-resolved-versions -c "$mode" --filter "$filter" || failed=1
    run "$mode-receipt" python3 - "$out/$mode-consumer.log" <<'PY' || failed=1
import re, sys
from pathlib import Path
s = Path(sys.argv[1]).read_text(errors="replace")
for name in (
    "listenStreamsOverServerSentEvents",
    "serverSentEventsParseSplitLinesCommentsAndMultilineData",
    "aChallengeIsAnsweredAndTheRequestSentOnceMore",
    "aRequestIsRetriedAtMostOnce",
    "aStepUpMayFollowAFirstAuthorization",
    "noRetryWithoutNewCredentials",
    "authorizesWithPKCEResourceAndStateThenSendsBearer",
    "acceptsAMissingIssWhenTheServerDoesNotAdvertiseIt",
    "rejectsForgedStateAndDeniedAuthorization",
    "rejectsTokensOtherThanBearer",
    "concurrentChallengesShareOneAuthorization",
    "metadataWithAnotherIssuerIsNotUsed",
    "aResourceThatDoesNotCoverTheEndpointStopsDiscovery",
    "candidateURLsFollowRFC8414AndRFC9728",
    "httpsPolicyIsUnchangedByTheLoopbackRules",
    "aLookalikeLoopbackTokenEndpointReceivesNoCodeOrRegistration",
    "preRegisteredClientsAuthenticateWithFormEncodedBasicCredentials",
    "registeredClientsUseTheMethodTheServerAssigned",
    "metadataDocumentsReplaceRegistrationWhenSupported",
    "scopeComesFromTheChallengeElseTheResourceElseIsOmitted",
    "stepUpAsksForTheUnionOfScopesAndOfflineAccess",
    "offlineAccessOnlyWhenOfferedAndWanted",
    "stepUpsStopAtTheLimitAndNeedInsufficientScope",
    "aRejectedTokenIsRefreshedWithoutTheUser",
    "aFailedRefreshFallsBackToAuthorization",
    "fragmentInAuthorizationRedirectIsRejected",
    "proactiveRefreshPersistenceFailureIsSurfacedAndRecovers",
    "tokensAreRefreshedShortlyBeforeTheyExpire",
    "aNewAuthorizationServerGetsItsOwnClientAndNoOldCredentials",
    "opaquePKCEVerifierSubstringIsNotAnOldRefreshToken",
    "storedAuthorizationSurvivesARestart",
    "storeFailuresAreReported",
    "findsTheBearerChallengeAmongOthers",
    "nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion",
    "nativeHTTPRepeatedFINReleasesOwnersAndRecovers",
    "nativeTLSPeerProcessExitCancelsBeforeResponseHead",
):
    assert re.search(r"Test " + name + r"\(\).*passed", s), f"Missing successful execution: {name}"
assert not re.search(r"recorded a known issue|recorded an issue|Test run with .* failed", s)
counts = [int(n) for n in re.findall(r"Test run with (\d+) tests?(?: in [^\n]*?)? passed", s)]
assert sum(counts) == 36, counts
print("Selected test executions:", sum(counts))
PY
    # Outside-root SwiftPM consumer links both real executable products.
    for product in SwiftConformanceServer SwiftConformanceClient; do
        run "$mode-$product" swift build --force-resolved-versions -c "$mode" \
          --package-path Tools/Conformance/SwiftFixture --product "$product" || failed=1
    done
done
exit "$failed"
