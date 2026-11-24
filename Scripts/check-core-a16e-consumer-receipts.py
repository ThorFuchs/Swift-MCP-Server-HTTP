#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify the fixed A1.6e B2 Swift Testing inventory, not a broad HTTP release gate."""
from pathlib import Path
import re
import sys

# Zero denotes a non-parameterized test. Positive values require the reported
# number of argument cases as well as the successful function-level receipt.
EXPECTED = {
    "clientAndServerInteroperateOverHTTP": 2,
    "listenStreamsOverServerSentEvents": 0,
    "serverSentEventsParseSplitLinesCommentsAndMultilineData": 0,
    "aChallengeIsAnsweredAndTheRequestSentOnceMore": 0,
    "aRequestIsRetriedAtMostOnce": 0,
    "aStepUpMayFollowAFirstAuthorization": 0,
    "noRetryWithoutNewCredentials": 0,
    "authorizesWithPKCEResourceAndStateThenSendsBearer": 0,
    "rejectsAuthorizationResponsesBeforeTheCodeIsSent": 4,
    "acceptsAMissingIssWhenTheServerDoesNotAdvertiseIt": 0,
    "rejectsForgedStateAndDeniedAuthorization": 0,
    "rejectsTokensOtherThanBearer": 0,
    "concurrentChallengesShareOneAuthorization": 0,
    "metadataWithAnotherIssuerIsNotUsed": 0,
    "aResourceThatDoesNotCoverTheEndpointStopsDiscovery": 0,
    "resourceCoverage": 9,
    "candidateURLsFollowRFC8414AndRFC9728": 0,
    "developmentLoopbackAcceptsLoopbackLiterals": 9,
    "developmentLoopbackRejectsEverythingElse": 33,
    "httpsPolicyIsUnchangedByTheLoopbackRules": 0,
    "aLookalikeLoopbackIssuerIsNeverContacted": 2,
    "aLookalikeLoopbackTokenEndpointReceivesNoCodeOrRegistration": 0,
    "preRegisteredClientsAuthenticateWithFormEncodedBasicCredentials": 0,
    "registeredClientsUseTheMethodTheServerAssigned": 0,
    "metadataDocumentsReplaceRegistrationWhenSupported": 0,
    "scopeComesFromTheChallengeElseTheResourceElseIsOmitted": 0,
    "stepUpAsksForTheUnionOfScopesAndOfflineAccess": 0,
    "offlineAccessOnlyWhenOfferedAndWanted": 0,
    "stepUpsStopAtTheLimitAndNeedInsufficientScope": 0,
    "aRejectedTokenIsRefreshedWithoutTheUser": 0,
    "aFailedRefreshFallsBackToAuthorization": 0,
    "duplicateOAuthRedirectKeysAreRejected": 3,
    "fragmentInAuthorizationRedirectIsRejected": 0,
    "proactiveRefreshPersistenceFailureIsSurfacedAndRecovers": 0,
    "tokensAreRefreshedShortlyBeforeTheyExpire": 0,
    "aNewAuthorizationServerGetsItsOwnClientAndNoOldCredentials": 0,
    "opaquePKCEVerifierSubstringIsNotAnOldRefreshToken": 0,
    "storedAuthorizationSurvivesARestart": 0,
    "storeFailuresAreReported": 0,
    "findsTheBearerChallengeAmongOthers": 0,
    "nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion": 0,
    "nativeHTTPRepeatedFINReleasesOwnersAndRecovers": 0,
    "nativeTLSPeerProcessExitCancelsBeforeResponseHead": 0,
}
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
PASS = re.compile(
    r"^[ \t]*\S+[ \t]+Test (\w+)\(([^()\n]*)\)"
    r"(?: with (\d+) test cases?)? passed after [\d.]+ seconds?\.[ \t]*$",
    re.MULTILINE,
)
SUMMARY = re.compile(
    r"^[ \t]*\S+[ \t]+Test run with (\d+) tests?(?: in [^\n]*?)?"
    r" passed after [\d.]+ seconds?\.[ \t]*$", re.MULTILINE,
)
BAD = re.compile(
    r"recorded (?:a known|an) issue|\b[1-9]\d* known issues?\b|"
    r"\bTest\b[^\n]*\b(?:failed|skipped)\b", re.IGNORECASE,
)


def verify(raw):
    log = ANSI.sub("", raw)
    if BAD.search(log):
        raise ValueError("failed, skipped, or known-issue test in log")
    seen = {}
    for name, arguments, cases in PASS.findall(log):
        if name not in EXPECTED:
            raise ValueError(f"unexpected successful test: {name}")
        if name in seen:
            raise ValueError(f"duplicate successful test: {name}")
        expected = EXPECTED[name]
        if expected:
            if not arguments or not cases or int(cases) != expected:
                raise ValueError(f"{name}: expected {expected} parameter cases, got {cases!r}")
        elif arguments or cases:
            raise ValueError(f"{name}: expected non-parameterized test")
        seen[name] = expected
    missing = sorted(EXPECTED.keys() - seen.keys())
    if missing:
        raise ValueError("missing successful tests: " + ", ".join(missing))
    counts = [int(n) for n in SUMMARY.findall(log)]
    if sum(counts) != len(EXPECTED):
        raise ValueError(f"expected {len(EXPECTED)} test functions, got {counts}")
    parameterized = {k: n for k, n in seen.items() if n}
    return len(seen), parameterized, sum(n or 1 for n in seen.values())


def main():
    if len(sys.argv) != 2:
        raise ValueError("usage: check-core-a16e-consumer-receipts.py LOG")
    count, variants, executions = verify(Path(sys.argv[1]).read_text(errors="replace"))
    for name, n in sorted(variants.items()):
        print(f"{name}: {n}/{n} parameter cases passed")
    print(f"PASS: {count}/{len(EXPECTED)} test functions; {len(variants)} parameterized functions; "
          f"{executions} individual cases including non-parameterized tests")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
