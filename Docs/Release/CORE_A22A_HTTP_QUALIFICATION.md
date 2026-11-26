# A2.2a — External HTTP qualification and admission probe

Status (2026-11-26): PREPARED; native execution NOT_RUN. Core PR #62
remains draft. This is an isolated diagnostic qualification, not an HTTP
release candidate, API expansion, or authorization to merge.

## Immutable inputs and existing evidence

- Core candidate: `cad67fb30817195c868bb45155097b4aeb0a68e5`,
  tree `ef1be9e60e750624549adbaf74078912a4dd9e51`, based on Core main
  `02115c26feba8a85d53631344bd501f36b1a8700`.
- Core [PR #62](https://github.com/ThorFuchs/Swift-MCP-Server/pull/62):
  425/425 documented native GREEN function executions; the original
  archive `core-a22a-green-Cl8lGEUg.tar.gz` was reopened in the authoring
  environment and its SHA-256
  `e42bda56ef3e8f94993137a9b9d0c107e224d7cccd4cf026ec9ddbf288ea2ca8`
  and 32/32 + 32/32 + 361/361 raw test summaries confirmed.
  [Normal CI](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45708242446)
  722/722 and [optimized CI](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45714652639)
  1444/1444, source-tree identity and dependency-byte verification.
  2591 cumulative executions, not distinct test functions.
- HTTP B3: `c99b65a9ee7879187e6d67e9771b8daa30115502`.
  Reuse the [N4.4 runner and receipt](CORE_A16N4_COMBINED_QUALIFICATION.md)
  as the baseline, without changing its code or historical evidence.
  Only the explicit Core revision in the disposable B3 manifests/locks
  changes. Preserve all other 28 pin records, including official NIO
  2.105.2, SQLite 1.2.0, the previously selected HTTP-server revision,
  and published referee 0.2.0-alpha.12 bundle SHA-256
  `b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0`.
- macOS ARM64 >=27, Swift 6.4.2, Node 24.22.3, npm 11.19.1, Python 3.
  No patched referee, changed timeout, new dependency or production
  HTTP source.

## Acceptance: three separate tracks

| Track | Debug | Release |
| --- | --- | --- |
| Unchanged B3 HTTP consumer tests | 43 named functions / 98 individual cases | same |
| Real SwiftConformanceServer / SwiftConformanceClient builds | both | both |
| Official server receipts | 37 frozen required + 13 extensions + 3 pending diagnostics | same |
| Official client receipts | 32 frozen required + 5 supplements, including 25 OAuth | same |
| Independent N3.2 native raw-wire probe | 1 fresh server process | 1 fresh server process |
| Isolated A2.2a public HTTP client admission probe | 1 parameterized function / 14 cases | same |

B3 and N3.2 are unchanged apart from Core selection. Preserve existing
raw-receipt gates, actual fixture executable hash verification, original
referee exits and shutdown markers. The only admissible official warning
is the exact historic Debug prompt observation SHOULD warning; never
count it as SUCCESS. Retain the exact Tasks upstream skip and two
client header skips per mode; no new warning, skip, failure or missing
required scenario. Expected raw successes: 241 or 242 Debug server,
242 Release server, 399 each client. 1281 historical successes if
the warning recurs; otherwise 1282. No claim of warning-free full
protocol qualification. The Tasks skip is not an implementation or
execution pass; its upstream rewrite stays outside this release task.

The new inventory checker hashes the frozen requirements file from the
actual fixture Core checkout (Git blob
`b0c4f8560429e8f4b6c89833cc0b35405bc004ff`), reads the two required
name lists and compares the exact sets plus explicitly selected
supplements. It also verifies the known skip identities and messages.
All non-skipped receipts must have positive SUCCESS counts. It supplements,
not replaces, the existing B3 receipt checks, which retain raw status
totals, original warning policy and process-exit ledgers.

## Targeted A2.2a probe

A finite synthetic loopback HTTP/1.1 SSE peer replies to the real public
`MCPClient.Client.listen` over `HTTPClientTransport`. No custom
ClientTransport and no SDK internals. A fresh peer is created per build
configuration. Each case uses an independent client and the actual
outgoing numeric ID. The peer verifies the requested known filter,
request metadata, and HTTP method/version headers. Swift asserts exact
callback sequence and typed outcome. The peer logs offered frames (not
an independent proof that every offered frame reached the client).
Require one request and one matching Swift receipt per case, successful
Swift test exit, no peer errors and joined peer.

| Case | Expected callbacks | Expected outcome |
| --- | --- | --- |
| valid-subset | ACK, tools | complete |
| callback-error | ACK | exact host callback error |
| before-ack | none | invalidResponse |
| foreign-ack | none | invalidResponse |
| duplicate-ack | ACK | invalidResponse |
| expanded-ack | none | invalidResponse |
| foreign-event | ACK | invalidResponse |
| unacknowledged-event | ACK | invalidResponse |
| foreign-terminal | ACK | invalidResponse |
| resource-uri | ACK | invalidResponse |
| extension-valid | ACK, extension | complete; raw task payload preserved |
| extension-foreign | ACK | invalidResponse |
| no-ack | none | invalidResponse |
| after-terminal | ACK | invalidResponse |

The Swift test overlay is copied only for this additional diagnostic
step, and removed in finally on ordinary completion or failure. It
must not exist in the baseline checkout, and its recorded bytes must
match the runner source. No shipping test target, manifest, runtime
source or fixture changes. Synthetic responses are finite; no sleep
chooses event ordering. The outer stage watchdog is the existing
2400-second diagnostic limit, not a changed SDK deadline.
This proves admission and propagation through the real HTTP client
on these paths, not physical cancellation/join of the Swift transport,
backpressure, reconnect, full extension authorization, or delivery of
real Tasks notifications by a native server. A2.2b/c/d remain separate.

## Integrity and authoring checks

The derivative runner preserves the previous 29-pin, eight-input-hash
and four-expected-Git-edits checks. Each of eleven graph verifications
also checks both actual Core checkout SHAs/trees and clean status.
The two overlay legs run after the corresponding unchanged B3 and N3.2
legs. Verify status and dependency hashes again after removing the
overlay. Expect 40 successful command stages, including 18 inherited
Python receipt controls, 12 inherited Node wire controls, 7 new Python
inventory controls and 6 new Python peer/receipt controls. The inherited
controls must execute again on Studio.

Authoring environment (Python 3.13.5 / Swift 6.2.1 x86_64):
- 7/7 inventory controls pass.
- 6/6 probe controls pass, including real loopback HTTP/SSE exchanges
  for all fourteen cases with a Python test client. Synthetic Swift
  receipt text tests the checker only.
- Read-only historical N4.4 archive replay: exact scenario names and
  historical skip identities pass in all four legs, using the required
  lists read from the frozen Core source. Runtime hash-gated file and
  checkout admission remain to be exercised by the native runner.
- Swift overlay parsed with swiftc -frontend -parse, not typechecked
  or linked against Swift 6.4.2. Exact remote/local tested blobs:
  inventory `0669778c854936f0a696da939905934b496f9abf`,
  peer/receipt `63f7a8c62b5dba9f78faceb72eb1e8c0740388c9`,
  overlay `b2091e6e901c3c0dab874a421b020020a66b96e7`.
- Derivative runner constructed by exact anchored edits to original
  `dbaf76b823af1c68c4af5bc91312f05eaec2cc08`; current blob
  `878db0dd67eeffcc7455bf8a68f64d59ae63bc23`. Remote source and
  step inventory inspected; whole-run syntax preflight on Studio.
  No native build/test/referee or full runner result yet.

## Native run and decision

Run after host/storage admission, no competing heavy Studio work.
Use a clean detached checkout of the exact diagnostic runner commit:

    export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    python3 -I Scripts/qualify-core-a22a-http.py EXACT_RUNNER_SHA /absolute/evidence/path

Prefer the verified mounted Backup volume (allow at least 30 GiB free
as a conservative admission threshold, plus internal cache headroom).
The launcher verifies source identity and Python syntax before running.
The runner retains logs, raw checks, peer offered frames, callback
receipts, graph/hash evidence and `core-a22a-http-*.tar.gz` on ordinary
success/failure. No generated evidence committed. Only
`PASS_SCOPED_A22A_HTTP_AND_ADMISSION` with all 40 steps and both native
admission/N3.2 receipts is an external pass. Review archive before any
integration. release_gate remains NOT_EVALUATED.

No merge, release tag, mutation of either main, final HTTP dependency
pair admission, AMD64 qualification or #29/#30 closure authorized.


## Native A2.2a external receipt — 2026-11-26

Status: **PASS_SCOPED_A22A_HTTP_AND_ADMISSION**, exit 0, release_gate
NOT_EVALUATED. Maintainer return `core-a22a-http-cwai6ix8.tar.gz`,
286,860 bytes, SHA-256
`535a5aaaef0ef97220e32ebb9c8480dd1786f3ccacbe1c8b96f7915561a30273`.
Original archive opened without extraction: 859 members, 542 regular files.
Exact runner `595e0efe9c9d2f509d0bc84cf35126693932770a`, Core `cad67fb30817195c868bb45155097b4aeb0a68e5`, tree
`ef1be9e60e750624549adbaf74078912a4dd9e51`, B3 HTTP
`c99b65a9ee7879187e6d67e9771b8daa30115502`. Native macOS 27.3 ARM64,
Swift 6.4.2, Node v24.22.3, npm 11.19.1.

40/40 successful stages; 18 inherited Python, 12 Node, seven inventory
and six peer controls passed. Independently summed the three raw Swift
Testing bundle summaries (3+7+33) per mode: 43 functions each; recorded
parameter inventory and consumer checker confirm 98 cases each.
Both 14-case Swift overlay logs show exactly the expected callback/verdict
sequences, one parameterized function passes with all 14 cases, zero exits.
Each peer records exactly 14 distinct requests, no errors and joined
supervisor. Original overlay bytes independently hashed from both archive
members: SHA-256 matches overlay receipts, Git blob
`b2091e6e901c3c0dab874a421b020020a66b96e7` matches published overlay.

| Leg | Raw scenarios | SUCCESS | WARNING | SKIPPED | INFO | Zero exits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Debug server | 53 | 241 | 1 | 1 | 0 | 4/4 |
| Debug client | 37 | 399 | 0 | 2 | 378 | 37/37 |
| Release server | 53 | 242 | 0 | 1 | 0 | 4/4 |
| Release client | 37 | 399 | 0 | 2 | 378 | 37/37 |

All 180 raw receipt names match the archived exact inventory plan,
37 required server plus 13 extension and 3 diagnostic names, 32 required
client plus five supplements, in each mode. Debug inventory compared
against the actual Core frozen required lists, Release identical.
All non-skipped scenarios contain executed SUCCESS checks. 1,281 SUCCESS,
0 FAILURE, one original Debug prompt observation warning, six historical
skips (Tasks status-notifications and two client headers per mode), 756 INFO.
No skip scored as success; no warning-free official claim.

Both independent N3.2 raw receipts confirm matching ACK/notification IDs
13/14 and exact prompt/tool catalog name-set additions, other catalog
unchanged. Observed prompt/tool ms: Debug 4486.862/4626.114; Release
457.349/470.977. Diagnostic single observations, not benchmark or isolated
transport latency. Two streams closed and post-close listings successful
per mode; all four server logs contain FIXTURE_STOPPED started=2 joined=2
active=0. N3.2 fresh process exits zero.

12 input-hash maps identical; all 11 graph and status receipts confirm
only four expected disposable manifest/lock changes, 22 actual Core
checkout SHA/tree/clean records match. All 29 pin records agree with root
and fixture lock snapshots; three archived before/after lock pairs
byte-identical and independently SHA-256 verified against recorded input
hashes. Runtime fixture and referee digest checks passed; executable and
bundle bytes omitted from archive, not independently rehashed here.
Existing HTTP unused dependency/effect-marker and cache diagnostics
remain visible.

Scoped Core PR #62 external gate satisfied. This is not qualification of
current HTTP main, general transport cancellation/join/backpressure, or
native Tasks notification delivery. A2.2b/c/d, platform and API gates
remain open. No new dependency, production source, or upstream referee
changes.
