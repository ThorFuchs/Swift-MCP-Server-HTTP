# H1 — Official SwiftNIO release integration (HTTP #12)

## Contract

Require SwiftNIO from 2.105.2. The exact H1 candidate is the official 2.105.2 tag at
`b003027fc38b649a43e9aad77c3d4e4a2c5b6997`, which contains Apple PR #3783
(merge `a7d4e6b50c9be24d3a55f1a50e6e52bfc1d683d5`).
The prior six-execution diagnostic proof is available in Actions run 45231924025;
it was against the upstream merge, not the released tag. Do not count it as H1.

H1 is based on HTTP main `d2e4cb5a07b4f2453ccd8106d799ca548470c202`.
Both lockfiles are seeded with the official NIO pin; every other pin, including
Core branch:main and its recorded revision, must be unchanged. The unverified
originHash fields are deliberately omitted from the candidate locks. SwiftPM
may regenerate them, but the field is optional. In the native 6.4.2 return
archive `http-h1-540jshab.tar.gz`, both resolves succeeded and both locks
remained byte-identical to the committed seeds (Git blob
`41ab82305cb3e38029e26f8e686937aedd5f8f2f`). The initial runner incorrectly
required the field and stopped after the graph checker passed, before any
HTTP tests. This is a qualification-harness correction, not a relaxation of
dependency or HTTP behavioral requirements. Preserve any valid SwiftPM-generated
origin hashes; never fabricate them. Review any native lockfile changes before
the final exact-head matrix.

Three existing native disconnect tests are mandatory in Debug and Release.
The old known-issue scopes are replaced by ordinary do scopes; the assertions,
deadlines and test bodies are otherwise unchanged. No production runtime,
HTTP-server dependency, referee or CI timeout change is in H1.

## Native run

Use an otherwise idle native ARM64 macOS 27+ machine, Swift 6.4.2, Python 3
and the project's pinned Node major. Start from a fresh, detached, clean
checkout of the exact H1 commit. Do not run timing-sensitive Core jobs in
parallel on the same physical machine.

    python3 -I Scripts/qualify-h1.py EXACT_HTTP_SHA "$HOME/MCP-H1-Evidence" full

Use `focused` instead of `full` to run just the graph and six native tests.
The runner checks both graphs against the immutable H1 baseline, verifies
all 29 actual checkout HEADs in each of the two workspaces after resolution
and after each successful test/build stage, records graph receipts (including
optional originHash), runs each named test separately and rejects
known-issue results or empty test filters. Full mode then runs Debug SDK,
Debug server/client referees, optimized libraries and both executable fixtures,
Release SDK/fixture tests and Release server/client referees.

The archive contains provenance, raw logs, passed stages, both native-resolved
lockfiles and their tracked diff. Inspect `decision.json` and
`focused-PASS.txt` separately from the overall exit. A later #20 linker
failure must not obscure a completed focused proof; it also must not be
described as a green release matrix.

If resolution changes any non-NIO pin, stop and inspect both locks. Do not
accept a newer mutable Core revision just to obtain a passing result. If the
runner reports malformed origin metadata, a missing checkout, or checkout drift,
treat that as a setup/integrity failure, not evidence about TCP behavior. No edits to the normal dependency
requirements, tests or timeouts to get the proof green.

## Release disposition

- Review the six real test executions against the released tag.
- Review native lockfiles; commit only admitted lockfile regeneration.
- Run the full exact-head matrix, including existing Linux compile-only CI.
- If optimized linking is still blocked by #20, retain H1 focused evidence,
  qualify #20 independently, then qualify the combined graph.
- Open/review a PR after the native pre-PR checks required by AGENTS.md.
- Close HTTP #12 only when the real release graph and its acceptance checks
  are integrated. HTTP #13, #25 and #14 remain independent gates.

## H1.1 — Runner regression controls

    python3 -I Scripts/test-qualify-h1.py -v

Authoring host: Python syntax check and 10/10 synthetic graph/lock controls
passed, including rejection of unrelated checkout drift and invalid present
origin metadata. Both actual archive lockfiles also passed the corrected lock
validator; Git checkout checks in the synthetic suite use mocks, not native
SwiftPM repositories. The original native archive establishes dependency
resolution and graph consistency, but no HTTP tests have run yet. No release
tag, main merge or issue closure is authorized by this document.

## H1.2 — Native full qualification review (2026-11-25)

**Disposition: native GO; integration CI pending.** Reviewed the supplied
`http-h1-9l6enh_w.tar.gz` (SHA-256
`8cfd14e434aff0d8a2ec434aa16a5885556cb8cea52ade394845c35a944eb289`).
This is a curated review of the evidence, not a committed raw archive. Retain the
original archive outside Git for independent replay.

### Provenance and integrity

| Input | Value |
| --- | --- |
| Qualified HTTP source | `9c1f78ebffee17718af8ebd828bb2cdff33e7b38` |
| Baseline HTTP main | `d2e4cb5a07b4f2453ccd8106d799ca548470c202` |
| Core checkout | `d892bd34add1ad067ae6f286bd74c824486d8c07` |
| SwiftNIO | 2.105.2, `b003027fc38b649a43e9aad77c3d4e4a2c5b6997` |
| swift-http-server | Existing revision `0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9` |
| Host | Native macOS 27.3 (26C5047e), ARM64 |
| Toolchain | Apple Swift 6.4.2 (swiftlang-6.4.2.1.9), Xcode 27.2 (27B52) |
| Mode / exit | full / 0 |
| Runner stages | 13/13 passed; focused_pass=true; release_gate=REVIEW_REQUIRED |

All 14 graph receipts (including the final receipt) are identical. Each records
29 checkout HEADs in each workspace, for 812 cumulative recorded revision
comparisons. Both native locks have Git blob
`41ab82305cb3e38029e26f8e686937aedd5f8f2f`, with optional originHash absent.
No lock or tracked source drift is reported. No lock regeneration commit is
needed for this candidate.

### Native test results

| Gate | Debug | Release |
| --- | ---: | ---: |
| HTTP SDK tests | 116/116 | 116/116 |
| Focused unmasked disconnect executions | 3/3 | 3/3 |
| Fixture tests (release qualification script) | Not separately run | 7/7 |
| Server referee required scenarios | 37/37 | 37/37 |
| Server implemented extension scenarios | 13/13 | 13/13 |
| Client referee scenarios | 37/37 | 37/37 |
| Client OAuth subset (included in 37) | 25/25 | 25/25 |

Total Swift test executions: 245/245, including repeat focused executions;
not 245 distinct test functions. No known-issue results in either SDK log.
Both optimized fixture executables linked successfully. The existing
connection-ceiling and both stalled-writer tests also passed in both modes;
the live-provider stalled-writer receipt records timeout=1 and cancelled=1.

| Focused native test | Debug seconds | Release seconds |
| --- | ---: | ---: |
| nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion | 15.039 | 1.459 |
| nativeHTTPRepeatedFINReleasesOwnersAndRecovers | 15.441 | 1.564 |
| nativeTLSPeerProcessExitCancelsBeforeResponseHead | 15.049 | 1.478 |

These are reported test durations, not isolated FIN detection latencies.

### Raw referee check review

Independently counted all archived checks.json records (53 server scenario
receipts, 37 client scenario receipts, in each configuration).

| Status | Debug server | Debug client | Release server | Release client |
| --- | ---: | ---: | ---: | ---: |
| SUCCESS | 241 | 399 | 242 | 399 |
| WARNING | 1 | 0 | 0 | 0 |
| FAILURE | 0 | 0 | 0 | 0 |
| SKIPPED | 1 | 2 | 1 | 2 |
| INFO | 0 | 378 | 0 | 378 |

The Debug-only SHOULD warning is
`sep-2575-server-sends-prompts-list-changed-on-subscription`.
Keep it visible; it corresponds to the separate Core/referee investigation
([conformance#600](https://github.com/modelcontextprotocol/conformance/pull/600)),
not a reason to change the official referee or declare complete coverage.
The server skip is `tasks-status-notifications`; the two client skips are
standard Mcp-Method header checks on initialize and notifications/initialized.
Three server scenarios per configuration are non-scored and have no failures.
Passing scenario gates is not equivalent to executing every check.

### Integration and remaining gates

- This receipt qualifies the exact source above, not the later documentation
  commit or an eventual squash-merge SHA. Run the unchanged CI matrix on the
  integration PR (macOS Debug/Release and Linux optimized compile-only).
- Verify the graph still uses the recorded Core revision; Core's independently
  advancing main is not an authorization to change this candidate's pins.
- Only close #12 after the release dependency and unmasked tests are integrated
  with admissible CI evidence. Keep diagnostic PR #27 open until then, and
  close it without merging once superseded.
- H2/#20 (provenance corrected by the 2026-11-25 reassessment): the ownership
  v3 correction had already entered main via #23, squash
  `7287b61910e713b5790f57e111e8d9273f46996c`. H1 qualified that existing
  implementation without a separate merge of #20. The identical transport
  blob is `1561da03862e2ccf19264ecba2acd101e70d3eac`. #20 was closed unmerged
  as superseded. Neither removing the correction nor attributing the earlier
  linker problem solely to SwiftNIO is supported by H1.
  See the [H2.1 source review](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/pull/20#issuecomment-7164622997).
- H3/#21 (official swift-http-server 0.5.0), H4/#25 (head/static writes),
  and H5/H6/#14 remain separate release gates. No Linux runtime support claim,
  Core release authorization, or HTTP RC1 GO follows from this receipt.
