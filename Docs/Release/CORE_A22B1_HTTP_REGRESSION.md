# A2.2b.1 — isolated external HTTP regression (Core PR #63)

Status (2026-11-27): PREPARED, native execution NOT_RUN. This is the
external regression gate for Core stdio cancellation admission and
active-exchange cleanup, not an HTTP lifecycle implementation or a
release decision.

## Immutable inputs

| Component | Identity |
| --- | --- |
| Core candidate | `5f6892cf9d3f81e1122612e9d3f3066ad0f03a3c` |
| Core tree | `c6b300777f6ba9d4d26c3d88df861a7b56f65c91` |
| Integrated Core base | `c82b0266cfd97a8dcaa82cd2eaa86a530ae7b1dd` |
| Previously qualified A2.2a tree | `ef1be9e60e750624549adbaf74078912a4dd9e51` |
| HTTP B3 source | `c99b65a9ee7879187e6d67e9771b8daa30115502` |
| Historical A2.2a diagnostic receipt branch parent | `046e4d5ea72c90944943d325be94094671b14edd` |
| Frozen Core requirements blob | `b0c4f8560429e8f4b6c89833cc0b35405bc004ff` |
| Published referee | 0.2.0-alpha.12 |
| Published referee index.js SHA-256 | `b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0` |

[Core PR #63](https://github.com/ThorFuchs/Swift-MCP-Server/pull/63),
[scoped native GREEN](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7215694488):
382/382 cumulative Core test executions.
[Normal Core CI](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45988409553)
passed 736/736 (368 per ARM64 platform); actual temporary merge commit
`32e90ed45a4851b8c08db89e00cd16e25592bd5f` has the exact candidate tree.
[Optimized Core CI](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45993815310)
was in progress at authoring. Finish that qualification and release the
Studio runner before starting the native HTTP run.

The integrated Core base tree was verified identical to the previously
qualified A2.2a tree. The new main-relative diff has exactly four paths:
one production change in StdioClientTransport.swift (+42/-9), two new
test files and one qualification document. No Core dependency-file or
frozen reference change. The B3 HTTP fixture remains untouched. Replace
only the Core revision in the disposable root and fixture manifests and
lockfiles. Preserve the other 28 pin records, including official
SwiftNIO 2.105.2, Swift-SQLite 1.2.0 and Swift-JSON 1.9.0. This is the
historical B3 graph, not an upgrade to Swift-JSON 1.10.0 or the current
HTTP main graph.

## Regression matrix and acceptance

Reuse the complete [A2.2a acceptance contract and native receipt](CORE_A22A_HTTP_QUALIFICATION.md).
Keep the old inventory and runner files, peer, overlay and referee scripts
unchanged. The two additional Python files differ from the earlier
runner/checker only in exact Core SHA/tree and the new runner/checker
paths, outcome, description and evidence-directory prefixes. Reverse
these substitutions and the original source matches byte-for-byte.

| Track | Debug | Release |
| --- | --- | --- |
| B3 HTTP consumer | 43 functions / 98 cases | 43 / 98 |
| Official server | 37 required + 13 extensions + 3 diagnostics | same |
| Official client | 32 required + 5 supplements | same |
| Independent N3.2 raw-wire notifications | one native fixture | one native fixture |
| Existing A2.2a HTTP admission | one parameterized function / 14 cases | same |

Require 40 successful command stages, 43 harness controls (18 Python
receipt, 12 Node wire, 7 inventory, 6 peer), 196 consumer cases and
28 admission cases. Keep the original exact scenario-name lists and
skip identities, 180 raw scenario receipts, 82 zero referee-command
exits. Expect 241 or 242 Debug server SUCCESS checks, 242 Release
server SUCCESS, 399 each client; no FAILURE. Permit only the original
Debug prompt SHOULD warning (at most one), Tasks notification scenario
skip and the two legacy client header skips in each mode. Preserve
historical skips as skips; do not treat a warning as a successful check.
The independent N3.2 receipts must remain green, with exact catalog
deltas and correlated notifications. The original fourteen-case
admission test and synthetic peer remain byte-identical.

Require eleven integrity checkpoints, 22 actual Core checkout SHA/tree
and clean-status records, 12 identical eight-input hash maps and
the four expected disposable manifest/lock changes only. Both native
SwiftPM resolutions must match all 29 expected pin records. Archive
the three before/after lockfile pairs, exact overlay bytes, raw test
logs, referee check JSON, peer receipts, actual fixture SHA receipts
and shutdown evidence. Do not commit generated evidence.

The result can be accepted only after actual archive review:
`PASS_SCOPED_A22B1_HTTP_REGRESSION`, all 40 stages exit 0, both
wire and admission legs PASS, all integrity gates satisfied.
The runner's release_gate remains NOT_EVALUATED.

## Authoring and source identity

- New runner Git blob `cadc0c80f709dee3bb94e5a18a57a90d360800c2`;
  original `878db0dd67eeffcc7455bf8a68f64d59ae63bc23`.
- New exact inventory checker blob
  `0c916a7b82eafd0f870586a22e736d2034964e71`; original
  `0669778c854936f0a696da939905934b496f9abf`. Only its Core SHA changes.
- Unchanged peer `63f7a8c62b5dba9f78faceb72eb1e8c0740388c9`,
  Swift overlay `b2091e6e901c3c0dab874a421b020020a66b96e7`,
  dependency checker `44a222b48045a36c6a7b7e92b509f8107132d3fd`,
  receipt controls `64c2bda65f79e02c47634d62c59d51c35c699dc8`,
  wire controls `4a9175a5ec8fa9fedd5326133553c7c064959252`,
  wire probe `2e30bdcbf1a552ec011cef4a3a49967ef044c29b`.
- Exact anchored substitutions reversed against fetched historical
  sources; fetched new blobs match authored text.
- Independent read-only Python replay of the original A2.2a archive
  `core-a22a-http-cwai6ix8.tar.gz` (SHA-256
  `535a5aaaef0ef97220e32ebb9c8480dd1786f3ccacbe1c8b96f7915561a30273`):
  all 180 raw scenario names agree with their archived inventory plans,
  1,281 SUCCESS, 1 WARNING, 6 SKIPPED, 756 INFO, no FAILURE,
  82 zero referee exits, 40 zero stages; both historical 98-case consumer,
  14-case admission and N3.2 receipts verified; both archived Swift
  overlay blobs rehashed. Historical root and fixture lock pairs match.
  Proposed one-pin replacement of the archived graph differs only
  in swift-mcp-server. This is historical replay, not native resolution
  or a candidate test result.
- Run the exact derivative's syntax preflight and all 43 existing harness
  controls on Studio. New native builds and referee execution NOT_RUN.

## Native run

Use exact diagnostic runner revision on native macOS ARM64 >=27,
Swift 6.4.2, Node 24.22.3, npm 11.19.1, Python 3. Prefer mounted
Backup volume with >=30 GiB free and adequate internal cache headroom.
No competing builds or benchmarks. The downloadable launcher checks
the exact checkout, runner/helper blobs and syntax, then executes:

    export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    python3 -I Scripts/qualify-core-a22b1-http.py EXACT_RUNNER_SHA /absolute/evidence/path

Return `core-a22b1-http-*.tar.gz`. Keep the workspace and original logs
on failure, preserve original warning and skip identities, and review
all native receipts before any integration decision.

## Non-goals

No new production HTTP tests or API changes; this reuses the existing
diagnostic overlay, not a shipping source edit. It does not prove HTTP
physical cancellation/join, active callback lifetime, reentrancy, remote
provider teardown, stale wire ID reuse, queue bounds or native Tasks
notification delivery. A2.2b.2–5, final HTTP dependency pair, AMD64 and
RC1 remain separate gates. No change to either main, no merge or tag.


## Native external regression receipt — 2026-11-27

**PASS_SCOPED_A22B1_HTTP_REGRESSION**, runner exit 0, release_gate
NOT_EVALUATED. Maintainer archive `core-a22b1-http-fdle_dql.tar.gz`,
289,695 bytes, SHA-256
`85ebc483851f19f6a471c2f26ba17ff52c1ea1d1f91abcb9f506716e2c488613`.
Opened without extraction: 859 unique member names, 542 regular files.
Exact runner `a9be781d06658e863934865056d34d3ede3a7a0a`; Core
`5f6892cf9d3f81e1122612e9d3f3066ad0f03a3c`, tree
`c6b300777f6ba9d4d26c3d88df861a7b56f65c91`; B3 HTTP
`c99b65a9ee7879187e6d67e9771b8daa30115502`. Native Darwin arm64,
macOS 27.3, Apple Swift 6.4.2, Node v24.22.3, npm 11.19.1.

All 40 command stages exit 0; raw harness logs confirm 18 Python
receipt + 12 Node wire + 7 inventory + 6 peer controls pass. Each
consumer leg has three passing Swift Testing bundle summaries
(3+7+33=43 functions) and the case receipt confirms all 98 individual
cases. Both independent admission logs contain exactly one passing
parameterized function, each of 14 unique expected typed outcomes and
callback sequences, matching 14 distinct request/filter/ID and offered
frame receipts, zero peer errors and joined peer. Both archived overlays
independently SHA-256 verified and Git blob matches
`b2091e6e901c3c0dab874a421b020020a66b96e7`. Offered frames are not
independent proof every offered byte reached the client.

| Leg | Raw scenarios | SUCCESS | WARNING | SKIPPED | INFO | Zero exits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Debug server | 53 | 241 | 1 | 1 | 0 | 4/4 |
| Debug client | 37 | 399 | 0 | 2 | 378 | 37/37 |
| Release server | 53 | 242 | 0 | 1 | 0 | 4/4 |
| Release client | 37 | 399 | 0 | 2 | 378 | 37/37 |

All 180 raw scenario names match the exact archived plans; required
lists agree with frozen Core requirements blob
`b0c4f8560429e8f4b6c89833cc0b35405bc004ff` and all four prior A2.2a
inventory groups. Only the historical Tasks notification skip lacks
a SUCCESS check in each server leg. Total 1,281 SUCCESS, 1 historical
Debug prompt SHOULD warning, 6 historical skips, 756 INFO, no FAILURE.
No skip or warning scored as a successful check.

Independent N3.2 native wire receipts: both PASS_N32_WIRE, actual ACK
and notification IDs 13/14 match, exact dynamic prompt/tool name-set
additions, other catalog unchanged; two streams closed, post-close
listings successful and process exit zero per leg. Both receipt fixture
digests agree with their scored server legs. All four server stderr logs
record FIXTURE_STOPPED started=2 joined=2 active=0. Diagnostic observed
prompt/tool times in ms: Debug 4432.691/4629.771, Release
457.734/470.740. These are single observations measured from mutation
start, not isolated transport latency or benchmark claims.

All 12 eight-input hash maps identical. Eleven graph verifications
and 11 raw status receipts pass, exactly four expected disposable
manifest/lock edits. All 22 actual Core checkout SHA/tree/clean records
match. Root and fixture before/resolved/after lock snapshots match
all 29 expected pins; the three before/after lockfile pairs are
byte-identical and independently hashed against input receipts.
Independent comparison to original A2.2a archive confirms the only
changed pin is swift-mcp-server. SwiftJSON 1.9.0 remains pinned.
Runtime referee/binary digest checks passed; their bytes are not
archived, not independently rehashed during this review.

Compared normalized raw log warning categories against A2.2a: no new
category. Existing unused HTTP dependency (8 log lines), unnecessary
try/effect marker (8 diagnostic lines), and Node DEP0190 (74 lines
from the client referee) remain at the same counts; the prior Git
checkout and NIO cache notices do not recur. This is not a warning-free
build or full security audit.

External HTTP gate for Core PR #63 satisfied. Separate Core
[optimized CI 45993815310](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45993815310)
concluded failure: Linux ARM64 Debug/Release 368/368 each, macOS
Debug 368/368, macOS Release fixture build aborted on ENOSPC
(No space left on device) before tests; both six-file dependency
verifications PASS. Optimized macOS DocC/inventory skipped after
failure. No successful complete optimized matrix yet. Recover runner
storage and re-run failed job on exact candidate; preserve failed
attempt. Merge HOLD until outstanding gate completes and maintainer
authorizes integration. No changes to Core source or either main.
