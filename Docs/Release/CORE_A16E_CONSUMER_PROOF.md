# A1.6e — external HTTP consumer diagnostic

This is a separate diagnostic branch, not an HTTP release candidate and not a merge of HTTP #20, #21 or #27. Core PR #60 is squash-merged at `02958abee82c363b879aa013c38229edb9a1c116` (tree identical to the qualified head). Base HTTP main: `d2e4cb5a07b4f2453ccd8106d799ca548470c202`.

Commit `3045a663ebdaff34c19f6d49de23de371a2bcac8` refreshes only the two HTTP lockfiles: Core branch main revision and Swift-SQLite 0.2.0 -> 1.2.0. The next commit selects official SwiftNIO [2.105.2](https://github.com/apple/swift-nio/releases/tag/2.105.2), `b003027fc38b649a43e9aad77c3d4e4a2c5b6997`. The release notes include apple/swift-nio#3783; Git ancestry verifies merge `a7d4e6b50c9be24d3a55f1a50e6e52bfc1d683d5` is an ancestor. No fork or package-edit override.

Only the three exact early-EOF known-issue wrappers in NativeListenerTests.swift become ordinary do scopes (test bodies, assertions and deadlines unchanged). This is safe only for this locked diagnostic graph; the public manifest minimum is deliberately unchanged until the HTTP release dependency decision. Keep separate HTTP #12, #13, #14 and #25 gates open. HTTP-specific swift-collections 1.6.0 and async-algorithms 1.1.5 pins remain; their compatibility with new Core needs native verification, not inference from Core CI.

Run on idle native macOS 27 with Swift 6.4.2, from a clean detached checkout at the diagnostic SHA:

    bash Scripts/qualify-core-a16e-consumer.sh EXACT_HTTP_SHA "$HOME/MCP-A16E-Evidence"

The script pins resolution, verifies both graphs and all selected named test receipts (including parameter case counts), tests the selected real HTTP client / OAuth / early-EOF cases in Debug and Release, and attempts to link both real conformance executable products in both configurations. It records exact source, locks, commands, status, logs and an archive even on ordinary failure. The focused tests and fixture links are not the full official protocol referees, whole HTTP SDK, optimized transport release qualification or stable SemVer dependency contract. A linker or resolver failure is a real result; do not fix it by silent graph changes or known-issue masking.

This candidate has not been compiled or tested natively at authoring time. Full referee/HTTP release and separate Linux AMD64 Core qualification remain outstanding.


## B1 native return (2026-11-24)

Archive `core-a16e-http-jQTLT7FO.tar.gz`, 19,446 bytes, SHA-256
`71d34c08dca3ff468846f6ad074aaf82872b2020cbc44349962c7cb1723c2f29`.
Exact source `edcf40cf46395012d6b8bed4b0d6b2a3f31daadf`; Apple Swift 6.4.2, macOS 27.3
(26C5047e), Darwin arm64, 16 CPUs. Exit 1; source status clean.
Both independent workspaces have the same 29 pins; the four manifest/lockfile
SHA-256 entries are identical before and after. Graph check passed.
SwiftConformanceServer built and linked in Debug (26.32 s) and Release
(52.26 s) with the existing HTTP-server revision, not the separate 0.5.0
candidate. SDK tests and SwiftConformanceClient compilation failed in both
configurations at five outdated API call sites. No HTTP test execution or
unmasked NIO runtime success is claimed.

## B2 — typed consumer migration and complete receipts

Commit `2d5449f0c8aae7f145a48232b7c15a5e9b336609` migrates only the five outdated call sites in
HTTPClientTransportTests.swift and ClientMain.swift to the existing Core
ElicitationResponse, SubscriptionFilter, SamplingResponse and [Root]
contracts. The typed API predates PR #60. Preserve the original wire content
(Ada/confirmed=true, assistant text ok and model conformance with no
stopReason, empty roots, toolsListChanged=true), existing assertions,
deadlines, test functions, and parameter cases. No production HTTP/Core
source, manifests, locks, known-issue masks or public signatures changed.
The unused direct swift-service-lifecycle warning is deferred, not suppressed.

The previous receipt checker omitted seven parameterized functions.
The selected source inventory is 3 HTTP client + 4 retry + 33 OAuth + 3
unmasked early-EOF functions = 43 per configuration. The seven parameterized
functions have 2, 4, 9, 9, 33, 2 and 3 argument cases respectively (62 total);
with the 36 unparameterized functions this is 98 individual cases per
configuration. The standalone checker requires each unique named successful
function, the exact expected case count per parameterized function, aggregate
43, and no failed/skipped/known-issue test receipts. No filters narrowed.
Authoring-host controls of the checker: complete synthetic receipt and
ANSI/Apple glyph/zero-test summary pass; missing/duplicate/unexpected
function, missing/wrong case count, wrong aggregate, failed/skipped/known-issue
receipts and actual B1 compile-failure logs reject. These are parser controls,
not native HTTP execution.

Run the same proof runner at the new exact branch head. Expect 43/43 functions
(98 cases) in each Debug and Release, both executable products in both
configurations, and unchanged dependency bytes. Full native B2 execution,
official referees and independent HTTP release gates are still open.
