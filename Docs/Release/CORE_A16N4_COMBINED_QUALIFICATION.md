# A1.6n.4 — combined Core and independent N3.2 qualification

Status: PREPARED; native combined external execution NOT_RUN. Core PR #61 remains draft. This diagnostic branch does not change production HTTP, Core main, HTTP main, the official referee, fixture source or ordinary release dependencies.

## Immutable inputs

- Integrated A2.1 Core base: `8e0e30d3c900e27ed24a143bdf9ac1dba7ffc133`.
- Original A1.6n performance candidate: `044e2ab332d9f55632c900c13f23502acd8e8972`.
- Combined Core PR #61 candidate: `4d0324921a2ce06f9d6a6414442a701817a31bec` (Git tree `5be6c1ff4998b6ece382f33e17db2fb1fdf5376d`); all 582 non-tree Git entries match the expected disjoint union. All four original performance blobs preserved. Expected 344 Core test functions per configuration; native full CI still required.
- HTTP B3 fixture: `c99b65a9ee7879187e6d67e9771b8daa30115502`. Only the explicit Core dependency revision changes in the disposable B3 root/fixture graph. Reuse 29-pin verification and eight input-hash snapshots from the passed A2.1 external qualification. Official SwiftNIO 2.105.2, Swift-SQLite 1.2.0 and referee alpha.12 remain unchanged.
- Published referee bundle SHA-256 `b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0`. No patched referee in scored runs.
- Native macOS ARM64 >=27, Swift 6.4.2, Node 24.22.3, npm 11.19.1, Python 3.

## Separate acceptance tracks

1. Performance candidate: preserve previous N1 measurements and failure receipt. Historical Debug prompt mutation mean 9.890015 -> 4.564381 s (-53.85%); tool 9.884046 -> 4.753123 s (-51.91%), three sequential repetitions per arm. Not a controlled ranking or a newly measured speedup of the combined candidate. Four reuse/accounting/changed schema/provider regression functions plus full combined Core Debug/Release CI, DocC, dependency integrity remain mandatory.
2. Official B2/B3 external regression: repeat the already passed A2.1 consumer contract in both configurations. Each mode: 43 named HTTP functions / 98 individual cases, both real fixture links, 37 required server and 37 selected client scenarios (25 OAuth), zero raw failures, exact historical skip distinctions, no new warning. At most the exact previously observed Debug prompt observation SHOULD warning is admissible in this scoped regression, disclosed verbatim. The original N1 zero-warning gate did not pass and is not rewritten. This independent scoped policy follows the N2/N3 evidence and is not a warning-free official protocol qualification or waiver of the underlying notification contract.
3. **N3.2 independent raw-wire:** in each mode start a fresh process of the exact previously built B3 server binary. No SDK/referee import. Use standard HTTP POST and MCP 2026-07-28 metadata, discovery, complete bounded catalog listing, two concurrent separately filtered subscriptions with exact ACK and JSON-RPC ID correlation. Confirm both synthetic dynamic entries are initially absent. After both ACKs, trigger prompt mutation then tool mutation on separate HTTP requests. Require each successful correlated complete mutation result, exactly one matching notification on the correct subscription, exact observed name-set change and no cross-filter/duplicate/preflight frame. Require an observation window after each completed RPC, an additional final quiet window, explicit stream abort and joined local readers, successful post-close list queries, and fixture exit 0 with its existing strict zero-ownership marker. Fresh process required per mode.

The N3.2 diagnostic client uses bounded opening (5 s), ordinary RPC (10 s), mutation (30 s), post-mutation observation (1.5 s), final quiet (1.5 s), preflight (100 ms), 8 MiB / 64 SSE-frame and 32-page caps. Its two acknowledged streams remain open during the mutation; they do not share an opening/observation timer. Parent watchdog (240 s for each raw-wire process) bounds the complete probe. These are **independent test-client budgets**, not changes to SDK, fixture or official referee deadlines. Observations record actual client-received frames and timestamps, not server-internal emission timestamps. Post-close requests prove continued service availability, not an independent measurement of subscription count before fixture shutdown; the existing fixture shutdown guard checks all owned resources before its exit marker. The probe is specific to this synthetic fixture, not a general SSE or MCP validation library, and does not prove every lifecycle path.

## Validation and execution

Authoring host Node 22.16.0: `node --check` and `node --test Scripts/test-core-n32-wire.mjs` passed 12/12. Real loopback HTTP/SSE mock: positive delayed mutation beyond opening budget, wrong ACK, wrong acknowledged filter, pretrigger event, early EOF, failed mutation, unchanged catalog, missing notification, wrong correlation ID, cross-filter delivery, duplicate frame and non-loopback refusal; mock subscription sockets close on return. Exact remote probe/test Git blobs `2e30bdcbf1a552ec011cef4a3a49967ef044c29b` and `4a9175a5ec8fa9fedd5326133553c7c064959252` match the tested files. No native Swift execution, fixture-process integration or full runner execution on the authoring host. The new runner is a narrow derivative of the A2.1 runner, preserving the old script and receipts, adding pinned combined Core, preflight controls and N3.2 per mode. On Studio, run all 18 inherited Python receipt controls and all 12 Node controls before native builds.

Run after Core CI and after host/storage admission; no parallel heavy runner work on the Studio:

    export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    python3 -I Scripts/qualify-core-a16n4-http.py EXACT_RUNNER_SHA /absolute/path/to/evidence

Use a clean detached checkout of the exact diagnostic runner SHA and preferably the verified writable Backup volume if internal free space remains low. The runner creates an isolated checkout, retains logs and produces core-a16n4-http-*.tar.gz even on ordinary failure. It verifies the native fixture binary digest immediately before/after each fresh N3.2 leg and rechecks all eight input bytes, actual Core checkouts and working-tree status. Only `PASS_SCOPED_A16N4_HTTP_AND_N32` with both native raw-wire receipts and all B2/B3 gates passing is a scoped combined external pass. Original official warning and six skips remain visible. No release tag, no final RC1 GO or merge authorization; Core #29, #30, AMD64 and final graph qualification remain separate.


## N4.4 native return — scoped PASS (2026-11-25)

Maintainer-provided archive `core-a16n4-http-2rdz1o54.tar.gz`, 277,536 bytes, 815 tar members, 500 regular files, SHA-256 `34319014463e9373225ed31f722d9cfacb352cab4390d211a58e1655b8d0bf51`. Reopened and checked without modifying or extracting the archive. Exact runner `652b0fef42315b2c61175eb62832fab73dafd66b`, combined Core `4d0324921a2ce06f9d6a6414442a701817a31bec`, HTTP B3 `c99b65a9ee7879187e6d67e9771b8daa30115502`. Native Darwin arm64 / macOS 27.3 / Apple Swift 6.4.2 / Node v24.22.3 / npm 11.19.1. Summary exit 0; decision **PASS_SCOPED_A16N4_HTTP_AND_N32**, release_gate=NOT_EVALUATED.

All 30 named qualification steps have exit 0; 18 Python and 12 Node harness controls passed. The two consumer receipt checkers each report 43/43 functions, seven parameterized functions and 98 individual cases (196 cumulative); four actual fixture build/link legs passed. The official referee results were independently enumerated from all 180 archived checks.json files and the exit ledgers:

| Leg | Scenario records | SUCCESS | WARNING | SKIPPED | INFO | Zero exits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Debug server | 53 | 241 | 1 | 1 | 0 | 4/4 |
| Release server | 53 | 242 | 0 | 1 | 0 | 4/4 |
| Debug client | 37 | 399 | 0 | 2 | 378 | 37/37 |
| Release client | 37 | 399 | 0 | 2 | 378 | 37/37 |

Total 1,281 SUCCESS, 0 FAILURE, 1 WARNING, 6 SKIPPED, 756 INFO; 82/82 command exits zero. Each server leg reports 37/37 required and 12 extension scenarios with successful checks; the pending Tasks status-notifications case is skipped, not passed. Both client legs report 37/37 named scenarios, including 25 OAuth; two historical Mcp-Method header skips per client leg. The sole warning is the original Debug prompt observation SHOULD check, with the exact historical ID and message. No new warning/skip/failure; original alpha.12 result preserved. This is a scoped regression, not a warning-free official conformance claim or retroactive N1 pass.

### N3.2 — independent native wire results

Both fresh fixture processes produce PASS_N32_WIRE. Independently checked the individual wire-receipt.json records against n32-receipts.json, the acknowledged filter/ID and received notification method/ID, and the exact catalog-set deltas (only the expected dynamic prompt/tool added, other catalog unchanged).

| Mode | Catalog | ACK / notification ID | Mutation RPC ms | Observed notification ms |
| --- | --- | ---: | ---: | ---: |
| Debug | prompts | 13 | 4449.567 | 4447.086 |
| Debug | tools | 14 | 4645.967 | 4646.066 |
| Release | prompts | 13 | 464.923 | 468.302 |
| Release | tools | 14 | 471.493 | 474.746 |

Times are relative to the probe's mutation start, not server-internal timestamps or isolated notification transport latency. The Debug prompt notification arrives before RPC completion; the probe deliberately accepts correlated notification during or after the successful mutation. Both Debug observations exceed the original referee's 1.5 s opening-to-observation timer, consistent with the prior causal trace. No new controlled A/B speedup, universal delivery guarantee, or claim that the upstream referee patch has been accepted.

Each mode records two closed streams, successful post-close listings, and fixture exit code 0 with no signal; all four server processes (official and independent) have the existing `FIXTURE_STOPPED started=2 joined=2 active=0` marker. Post-close lists show service availability, not an independent count of subscriptions before shutdown. The N3.2 fixture digest matches the corresponding official server fixture receipt in both configurations. Executable and installed referee bundle bytes are not included in the archive; integrity at runtime is attested by the runner's recorded successful checks, not independently rehashed from omitted binaries.

### Dependency and scope review

All 29 complete pin records match expected/root/fixture before, after and resolved lock snapshots, including exact combined Core, official SwiftNIO 2.105.2 and Swift-SQLite 1.2.0. All ten eight-file input hash snapshots equal; the root/fixture/npm before and after archived lockfiles are byte-identical and independently SHA-256 verified against the manifest. All nine graph verification logs confirm both actual Core checkouts and 29 pins; all nine raw status receipts contain only the four expected unstaged diagnostic manifest/lockfile changes. Existing unused swift-service-lifecycle dependency and unnecessary try effect-marker warnings remain in the diagnostic HTTP consumer logs; no warning-free HTTP build claim.

Pre-merge Core CI: [normal](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45669090782) 688/688 and [optimized](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45670519886) 1,376/1,376 function executions; both source trees identical to the combined candidate. The A2.1 post-merge run separately passed 680/680. N4.4 satisfies the documented scoped external gate for Core PR #61. N4.5 integration is a separate maintainer decision and exact merged-main CI. No generated archives or absolute host paths committed. No current HTTP/main release-graph qualification, final RC1 GO, or closure of remaining #29/#30/platform gates.
