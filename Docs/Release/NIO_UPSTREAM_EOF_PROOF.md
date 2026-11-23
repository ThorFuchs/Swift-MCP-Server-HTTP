# HTTP #12 — Apple SwiftNIO upstream early-EOF consumer proof

**Status:** Diagnostic only; no production package or release dependency is changed.

## Verified reference

- Upstream PR: https://github.com/apple/swift-nio/pull/3783
- Accepted merge: a7d4e6b50c9be24d3a55f1a50e6e52bfc1d683d5
- Published SwiftNIO 2.105.1 predates the merge and does not contain it.
- Root and conformance fixture currently resolve swift-nio 2.105.0; both release pins remain untouched by this PR.
- Earlier downstream fork proof: https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45059593224

## What the proof does

1. Requires macOS 27+ and Swift 6.4.2, a clean source checkout, and records exact source/OS/toolchain revisions.
2. Creates disposable, isolated HTTP and official Apple SwiftNIO checkouts.
3. Checks out the exact merged Apple commit, not a private fork, moving branch, or published package version.
4. In the disposable test source only, replaces exactly three named early-EOF known-issue wrappers with ordinary do scopes. All assertions, deadlines, and test bodies remain unchanged. The original checkout and production manifest are untouched.
5. Applies SwiftPM local edit overrides separately to the HTTP root and Conformance fixture workspaces. Inspects both dependency graphs; rejects all unrelated package-pin drift.
6. Requires each named case to be actually executed and pass under both Debug and Release builds (six focused receipts), rather than treating an empty filtered run as green.
7. Saves individual logs, diff, resolved graphs, and provenance into a CI artifact even on failure.

The three protected cases are:
- nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion
- nativeHTTPRepeatedFINReleasesOwnersAndRecovers
- nativeTLSPeerProcessExitCancelsBeforeResponseHead

## Usage

On the named diagnostic branch, the dedicated GitHub Actions workflow runs the focused macOS proof on push. It is intentionally separate from the normal release CI.

For a controlled local run on Mac Studio or MacBook (no concurrent large Swift builds):

    bash Scripts/qualify-swiftnio-upstream-eof.sh

Once the focused proof passes, an operator can run a heavier, same-SHA diagnostic with:

    MCP_NIO_PROOF_MODE=full bash Scripts/qualify-swiftnio-upstream-eof.sh

Full mode additionally runs unmasked complete Debug/Release SDK tests, optimized server/client fixtures, and official server/client referees. It retains outputs and never blesses the edited workspace as a distributable release dependency.

## Release gate (still open)

Even a green diagnostic proves only consumer behavior using this exact untagged upstream source on the tested host and graph. HTTP #12 cannot close until an official released SwiftNIO version containing the merge is selected in the actual package manifests and root/fixture locks, all three wrappers are removed from tracked source, and the full release matrix passes on the immutable resulting dependency graph.

No changes to SocketChannel, KQueue, production HTTP logic, Core versioning, or test timeouts are made by this diagnostic PR. It does not resolve HTTP #25 (response-head/static writer ownership) or #13 (official swift-http-server version qualification).
