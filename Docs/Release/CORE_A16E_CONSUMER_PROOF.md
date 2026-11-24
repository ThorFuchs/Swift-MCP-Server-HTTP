# A1.6e — external HTTP consumer diagnostic

This is a separate diagnostic branch, not an HTTP release candidate and not a merge of HTTP #20, #21 or #27. Core PR #60 is squash-merged at `02958abee82c363b879aa013c38229edb9a1c116` (tree identical to the qualified head). Base HTTP main: `d2e4cb5a07b4f2453ccd8106d799ca548470c202`.

Commit `3045a663ebdaff34c19f6d49de23de371a2bcac8` refreshes only the two HTTP lockfiles: Core branch main revision and Swift-SQLite 0.2.0 -> 1.2.0. The next commit selects official SwiftNIO [2.105.2](https://github.com/apple/swift-nio/releases/tag/2.105.2), `b003027fc38b649a43e9aad77c3d4e4a2c5b6997`. The release notes include apple/swift-nio#3783; Git ancestry verifies merge `a7d4e6b50c9be24d3a55f1a50e6e52bfc1d683d5` is an ancestor. No fork or package-edit override.

Only the three exact early-EOF known-issue wrappers in NativeListenerTests.swift become ordinary do scopes (test bodies, assertions and deadlines unchanged). This is safe only for this locked diagnostic graph; the public manifest minimum is deliberately unchanged until the HTTP release dependency decision. Keep separate HTTP #12, #13, #14 and #25 gates open. HTTP-specific swift-collections 1.6.0 and async-algorithms 1.1.5 pins remain; their compatibility with new Core needs native verification, not inference from Core CI.

Run on idle native macOS 27 with Swift 6.4.2, from a clean detached checkout at the diagnostic SHA:

    bash Scripts/qualify-core-a16e-consumer.sh EXACT_HTTP_SHA "$HOME/MCP-A16E-Evidence"

The script pins resolution, verifies both graphs and all five critical named receipts, tests the selected real HTTP client / OAuth / early-EOF cases in Debug and Release, and attempts to link both real conformance executable products in both configurations. It records exact source, locks, commands, status, logs and an archive even on ordinary failure. The focused tests and fixture links are not the full official protocol referees, whole HTTP SDK, optimized transport release qualification or stable SemVer dependency contract. A linker or resolver failure is a real result; do not fix it by silent graph changes or known-issue masking.

This candidate has not been compiled or tested natively at authoring time. Full referee/HTTP release and separate Linux AMD64 Core qualification remain outstanding.
