# N3.1 — Native Swift cross-referee qualification

Diagnostic only. Core main, HTTP main, Core PR #57/#61 and upstream conformance #600 must remain unchanged by this proof.

## Pinned inputs

- HTTP fixture: c99b65a9ee7879187e6d67e9771b8daa30115502 (B3).
- Core: 044e2ab332d9f55632c900c13f23502acd8e8972 (untraced #61 candidate, the same production candidate used in N1).
- Published referee: 0.2.0-alpha.12, bundle SHA-256 b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0.
- Candidate: ThorFuchs/conformance at b0fa91d7cef7d844e35a5526e2c9a7549e25dd83, bundle SHA-256 0d65ec7ba15f0f9a7f977cc7bec612f1592166287fcb57f1ae3cd83c46e23236.
- Apple Swift 6.4.2, native ARM64 macOS, Node 24.22.3, npm 11.19.1.

Use the existing clean upstream candidate checkout and previously qualified dist/index.js. If unavailable, clone the fork at the exact commit and run locked npm ci and npm run build; do not waive a bundle hash mismatch. The runner stages the candidate as a separate sibling in the disposable published package directory, retaining the original bytes and shared runtime dependencies/requirements. Any missing module or execution failure is a failed proof, not permission to update dependencies.

Run from a clean checkout of this diagnostic runner, on an otherwise idle Studio:

    python3 -I Scripts/qualify-core-a16n3-referees.py EXACT_RUNNER_SHA "$HOME/MCP-A16E-Evidence" /absolute/path/to/conformance

The inherited N1 checker seeds only the explicit Core revision in both disposable manifests/locks; native SwiftPM recomputes origin hashes. All other 28 pins must agree, both actual Core checkout SHAs must match, and eight manifest/lock inputs are hashed after resolution, builds and every leg. Build each configuration once; each paired leg uses the same executable hash. Each leg starts a fresh fixture with a nonce-authenticated readiness receipt. Original/candidate bundles are checked before and after the runs. No tracked production source, manifest, lock or protocol requirement changes on the runner branch.

## Ordered matrix and decision

| Leg | Referee | Expected checks (hypothesis) |
| --- | --- | --- |
| Debug 1 | Original | 29/30; exact original prompt observation warning |
| Debug 1 | Candidate | 30/30 |
| Debug 2 | Candidate | 30/30 |
| Debug 2 | Original | 29/30; exact original prompt observation warning |
| Release 1 | Original | 30/30 |
| Release 1 | Candidate | 30/30 |

Require all 30 unique check IDs and the same set across six legs, no FAILURE/SKIPPED, real successful prompt/tool change frames (including subscription IDs) wherever scored SUCCESS, the original initial mutations, and graceful fixture exit/join. The runner uses the existing N1 raw receipt checker plus stricter mode/warning classification. It does not independently correlate a subscription ACK with the notification ID; that remains a separate raw-wire regression. Do not count a warning about an untestable mutation as the reproduced observation warning.

Exit 0: PASS_DIAGNOSTIC (all legs admissible, at least one original Debug warning reproduced, both candidate Debug runs and both Release runs clean). Exit 2: INCONCLUSIVE_NO_ORIGINAL_WARNING (all legs clean, so differential not demonstrated). Exit 1: failed gate, setup or integrity failure. Preserve the archive on ordinary failure. A watchdog-triggered forced termination cannot produce a passing receipt.

The published bundle and upstream candidate may differ in other upstream source changes; this comparison isolates the referee artifact, not necessarily the three-file patch from all upstream history. The separate existing source-level loopback proof provides complementary evidence. If attribution needs further isolation, add a matched upstream-base build in a separate diagnostic.

Even a PASS_DIAGNOSTIC does not replace an official scored referee result, approve upstream #600, merge #61, establish a release gate, or prove all notification/lifecycle paths. Review archived raw checks and fixture logs before updating the issue. Preserve the original warning, exact graph and official referee score; do not adjust server deadlines, requirements, check severities or timeouts.

## Authoring validation

Python syntax and focused synthetic receipt/process controls were exercised on the authoring host; no native Swift run or patched-referee execution has been observed at authoring time. Native evidence must be returned from the Studio.
