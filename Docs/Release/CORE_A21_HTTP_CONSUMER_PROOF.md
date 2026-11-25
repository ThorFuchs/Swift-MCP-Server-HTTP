# A2.1 — external HTTP consumer proof (2026-11-25)

Status: prepared; native execution NOT_RUN. Core PR #57 remains draft. This is a controlled external-consumer regression against the already qualified A1.6e B2/B3 diagnostic graph, not HTTP release qualification. H1 and other parallel HTTP work remain independent.

## Immutable inputs

- HTTP source: `c99b65a9ee7879187e6d67e9771b8daa30115502` (B3, includes B2 consumer fixes).
- Previously qualified Core: `02958abee82c363b879aa013c38229edb9a1c116`.
- Sole changed dependency revision: Core A2.1 `1237d9f11e580f9c68ba6d7064d0c16de7fa1cd3` ([PR #57](https://github.com/ThorFuchs/Swift-MCP-Server/pull/57), [optimized CI](https://github.com/ThorFuchs/Swift-MCP-Server/actions/runs/45601748853)).
- Published referee 0.2.0-alpha.12 bundle SHA-256 `b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0`. No candidate or patched referee.
- Native macOS ARM64 >=27, Swift 6.4.2, Node 24.22.3, npm 11.19.1, Python 3.

The runner clones its own repository into a disposable checkout, detaches at B3 and reuses the N1 pin seeder/checker. Change the Core branch requirement to the exact candidate revision in root and fixture manifests; seed the corresponding lock entries; let native SwiftPM calculate the origin hashes. Require both actual Core checkouts and all 29 complete pin records (only Core differs from B3), then lock resolution. SwiftNIO 2.105.2 and Swift-SQLite 1.2.0 remain unchanged. No package edits, no production source edits or tracked lockfile changes on any regular branch. Hash eight input files after initial native resolution and each successful gate, retain both workspace lockfiles and npm lock before/after, verify that only the four intentional disposable Swift manifest/lock edits exist.

## Acceptance (targets, not results)

| Gate | Debug | Release |
| --- | --- | --- |
| B2 named HTTP/client/OAuth/native early-EOF tests | 43/43 functions, 98 cases | 43/43 functions, 98 cases |
| External fixture links | server and client | server and client |
| B3 required server scenarios | 37/37 | 37/37 |
| B3 selected client scenarios | 37/37 | 37/37 |
| Actual server scenario records | 53 (required + extension/diagnostic records) | 53 |
| Actual client scenario records | 37 | 37 |
| Raw server successes | 241 or 242 | 242 |
| Raw client successes | 399 | 399 |

Reuse original B2 named/parameter-case receipts, B3 scenario/exit inventory checks and unmodified conformance scripts. In each mode the two fixture builds/links are part of the respective referee script; additionally rehash the actual fixture executable against its recorded digest and verify the original referee bundle. Require server fixture stopped/joined marker, all 82 referee exits zero, no raw FAILURE, and no new warning/skip status. The sole previously reproduced warning permitted in the scoped Debug server regression is the exact prompt-list-change observation warning (not an untestable mutation); report its full original receipt, never count it as SUCCESS. The previously pending Tasks status-notifications server skip and the two client Mcp-Method header skips (initialize and notifications/initialized) remain SKIPPED. No warning-free official Tier-1 or Tasks status-notifications coverage claim. INFO records are not successes. The new raw audit deliberately compares the historical inventory, not an updated referee baseline.

The runner uses an outer bounded subprocess watchdog (40 minutes per main build/test/referee step, shorter for setup/validation); it fails closed, terminates the process group on timeout and retains an archive on ordinary failure. Existing scenario deadlines, test assertions, and B3 scripts are unchanged. It stops on the first failed gate. The watchdog is not complete OS-level process containment; original referee exit receipts and server fixture join marker are not proof of all client-internal teardown paths.

## Execute on the Studio after coordinating runner/host availability with the parallel HTTP and EngineBench sessions

    export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    python3 -I Scripts/test-core-a21-http-receipts.py
    python3 -I Scripts/qualify-core-a21-http.py EXACT_RUNNER_SHA "$HOME/MCP-A21-Evidence"

Use a clean detached checkout of this diagnostic branch's exact commit. The runner creates its own isolated build workspace; evidence and retained checkout live outside the runner repository. Do not run simultaneous heavy qualification on the same host. Upload the printed core-a21-http-*.tar.gz archive, including on failure.

Review raw results, step receipts, source and dependency hashes, fixture digests and all warnings/skips before an integration decision. PASS_SCOPED_A21_HTTP_INTEROP is not RC1 approval, complete HTTP release matrix, N3.2 raw-wire regression, or closure of Core #29. Final qualification on the actual future merged Core/HTTP release graph is separate.

## Authoring checks

Python syntax validation and 11/11 synthetic unit controls passed locally (3 positives, 8 negatives: missing/duplicate scenarios, raw failure, wrong/unadmitted warning, untestable mutation, wrong skip). The new full runner has not been executed against SwiftPM, the native HTTP fixture or the published referee here; the native archive is required. No CI dispatch, merge, tag, performance score, or actual A2.1 interoperability result.

## A2.1a — working-tree receipt correction (2026-11-25)

Maintainer console return from original runner `16f13068522c84edb98d3732631acf9d11c2c7ee`: Node/npm/Swift preflight and 11/11 synthetic controls passed, disposable clone/checkout/seed, both native resolutions and `verify-resolved` exited 0. Then the runner failed with `unexpected tracked/untracked changes`; archive `core-a21-http-z1mh7ojm.tar.gz` remains on Studio and has not been independently inspected here. No native HTTP test or referee execution occurred. The original failure remains recorded.

The generic capture helper stripped significant leading porcelain status whitespace: a legitimate ` M Package.resolved` first line became `M Package.resolved`, and slicing at offset three produced `ackage.resolved`. Independently reproduced using a real temporary Git repository containing the four expected unstaged edits. The new dedicated status check retains the raw output bytes in each receipt and requires exactly the four expected ordinary unstaged modifications, with untracked files explicitly enumerated and rename detection disabled. No dependency/hash/test/referee/timeout acceptance criterion is relaxed. Seven real-Git regression controls passed on the authoring host, including the old-parser reproduction and six rejection cases. The revised repository test suite contains the prior eleven receipt controls plus seven working-tree controls; execute all eighteen on Studio before retrying native qualification. The precise contents of the original failed status receipt remain to be checked if there is any further unexpected change.

The console also reports only 12 GiB available (98% capacity). Coordinate host availability and free sufficient scratch capacity before rebuilding; do not delete the failed archive or blindly remove existing workspaces. The corrected runner is not yet natively qualified. Core/HTTP production source and dependency graph, PR #57/#61 and parallel H1 remain untouched. No merge or tag.


## A2.1b — native consumer return: PASS (2026-11-25)

Maintainer-provided archive `core-a21-http-utl9vgw1.tar.gz`, 272,865 bytes, 792 tar members, 479 regular files, SHA-256 `5e8799bbd95045dead28432628f6d7458525bc88dad9fffb495e1fcf3f04638c`. Runner `d5a72f9bb963334c600e4c3ee7ed76da9795443f`, unchanged B3 HTTP `c99b65a9ee7879187e6d67e9771b8daa30115502`, sole selected Core revision `1237d9f11e580f9c68ba6d7064d0c16de7fa1cd3`. Native Darwin arm64, macOS 27.3, Apple Swift 6.4.2, Node 24.22.3, npm 11.19.1.

All 24 runner steps exited 0; original summary exit 0 and decision **PASS_SCOPED_A21_HTTP_INTEROP**, release_gate=NOT_EVALUATED. Debug and Release each have 43/43 named consumer functions, seven parameterized functions with 62 individual argument cases plus 36 unparameterized cases (98/98 per mode); the four actual fixture product build/link legs and their recorded hash checks passed. Both server fixtures record started=2 joined=2 active=0.

| Referee leg | Scenario records | SUCCESS | WARNING | SKIPPED | INFO | command exits 0 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Debug server | 53 | 241 | 1 | 1 | 0 | 4/4 |
| Release server | 53 | 242 | 0 | 1 | 0 | 4/4 |
| Debug client | 37 | 399 | 0 | 2 | 378 | 37/37 |
| Release client | 37 | 399 | 0 | 2 | 378 | 37/37 |

Independently reopened the archive and enumerated all 180 raw scenario receipts and 82 zero exit records. Total 1,281 SUCCESS, zero FAILURE, one exact historical Debug prompt subscription SHOULD WARNING, six SKIPPED, 756 INFO. The skip reasons are the pending Tasks subscription notification rewrite (one per server leg) and unexercised initialize/notifications/initialized Mcp-Method headers (two per client leg). Each server leg passes 37/37 required scenarios and has successful checks in 12 extension scenarios; one extension remains pending. Each client leg passes the 37 selected scenarios including 25 OAuth. Preserve actual official scores, not a warning-free or complete protocol coverage claim.

All 29 full pin records match across root/fixture and expected graph; seven actual Core checkout verifications PASS. All eight input-hash snapshots are identical; three archived before/after lock pairs (root, fixture, npm) independently rehashed and match. All seven raw status receipts contain only the four expected ordinary unstaged manifest/lock edits; corrected status parser passes on the native graph. Executable and published referee integrity are established by the recorded successful runner checks, not independent rehashes of omitted binary/bundle bytes. Existing unused direct swift-service-lifecycle dependency warning and unnecessary try effect-marker diagnostics in HTTP OAuthClientTests.swift occur in both configurations; no warning-free HTTP build claim or Core source defect inferred.

The original failed A2.1a attempt remains distinct. This return satisfies the scoped B2/B3-equivalent external gate for Core #57; it does not qualify the newer HTTP/main release graph, close Core #29, establish N3.2, or authorize a release tag. Core integration decision and post-merge CI are separate. No generated archive, private paths or machine-specific evidence files committed.
