# A2.2b.2 — external HTTP regression for Core PR #64

Status: PREPARED; native execution NOT_RUN. Reuse the accepted
[A2.2b.1 contract and native receipt](CORE_A22B1_HTTP_REGRESSION.md).
The exact same isolated B3 HTTP source, official referee, independent
N3.2 wire probes and fourteen-case A2.2a admission overlay are used.
Only the Core revision in the disposable manifests and locks changes.

| Identity | Value |
| --- | --- |
| Core candidate | `d3a0bdcceaca43dd7dc8d05762524928b3293ee4` |
| Core tree | `0e48f0d522a45115f7acfa6b38c45d0742ffa082` |
| Integrated Core base | `415f62594e87a573ebea1f2bb701d5c24ad92cc1` |
| B3 HTTP source | `c99b65a9ee7879187e6d67e9771b8daa30115502` |
| Previous diagnostic parent | `58f2ae212b781c57c5ba2a6a0334a518aae5fbd9` |
| Frozen required inventory | `b0c4f8560429e8f4b6c89833cc0b35405bc004ff` |
| Referee version | 0.2.0-alpha.12 |
| Referee index.js SHA-256 | `b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0` |

[Core PR #64](https://github.com/ThorFuchs/Swift-MCP-Server/pull/64)
and [native GREEN receipt](https://github.com/ThorFuchs/Swift-MCP-Server/issues/29#issuecomment-7230278779).
This regression does not assert HTTP caller-owned delivery or physical
SSE cancellation/cleanup; the only shipping Core production change in
A2.2b.2 is StdioClientTransport.swift. A2.2b.5 remains a separate gate.

New runner blob `0d717b8656b26950d80fe703e269e344fc3767a3`,
new inventory checker `e3e489dfea441dd26a61919cb92166844fb583fd`.
Fetched contents compared with authored text; reversing exact anchored
Core SHA/tree, checker path and receipt/prefix/name substitutions
reconstructs previous accepted runner/checker byte-for-byte.
Historical sources and receipts unchanged. No new native execution or
local Python control execution claimed at preparation.

Acceptance: 40 zero command stages, 43 harness controls, 196 HTTP
consumer cases (43 functions / 98 cases per mode), 28 admission cases,
180 exact scenario records, 82 zero referee exits, 2 independent N3.2
wire receipts, four native server join markers. Expected 1281 or 1282
official SUCCESS, zero FAILURE, at most original Debug prompt SHOULD
warning and exactly six historical skips. No new warning category.
Keep 29 pinned dependencies, 11 graph/status checks and 22 actual Core
SHA/tree/clean checkout records, 12 identical eight-input hash maps,
three lock pairs and exact archived overlay bytes. Original historical
warning and skip identities are retained, not scored as success.
SwiftJSON 1.9.0 remains intentionally frozen in B3.

Run only after normal and optimized Core CI and other Studio-heavy
work are complete, on macOS ARM64 >=27, Swift 6.4.2, Node 24.22.3,
npm 11.19.1. Check mounted Backup volume and available space plus
internal cache headroom. Clone this diagnostic repository into a fresh
workspace, detach at exact runner revision, check clean status and
source blobs. Syntax check the two new Python files, then execute:

    export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
    python3 -I Scripts/qualify-core-a22b2-http.py EXACT_RUNNER_SHA /absolute/evidence/path

The runner runs all original controls and preserves evidence on ordinary
failure. Expected archive core-a22b2-http-*.tar.gz, outcome
PASS_SCOPED_A22B2_HTTP_REGRESSION; release_gate NOT_EVALUATED.
Review original return archive before accepting. No change to either
main, no new dependencies, workflow changes, tag or release decision.
