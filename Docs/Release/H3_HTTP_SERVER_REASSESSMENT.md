# H3.1 — Official Swift HTTP Server dependency reassessment

**Status:** diagnostic prepared; native H3.1 run pending. Do not merge this
branch, change the shipping backend, or close #13/#21 on this basis.

## Provenance correction from H2

The ownership v3 implementation is already integrated via PR #23, squash
`7287b61910e713b5790f57e111e8d9273f46996c`. The transport blob
`1561da03862e2ccf19264ecba2acd101e70d3eac` matches #20 v3 and H1 main.
PR #20 is closed unmerged as superseded. H1 did not pass without the existing
ownership correction; it passed without a separate merge of #20. Correct the
historical H1 document wording in the next regular documentation-bearing change.

## Established historical evidence

- [Combined default-backend run 45073773028](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45073773028):
  PR20 v3 plus PR21's published 0.5.0 dependency removed the original Connection
  error from the full server link, but Reader.State and Reader.State.Reading
  metadata remained undefined. Four independent external dynamic-library
  consumers in the mini package removed MCP and networking from the failure.
  Release ConnectionTransfer linked; ConnectionDrop, ReaderDrop and
  ReaderCollect reproduced matching undefined metadata.
- [Native-backend run 45075398908](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45075398908):
  the combined server and all four optimized external probes linked and the
  exported probe symbols were verified. Within each full/mini comparison the
  dependency graph was kept fixed (29/24 pins respectively). Both backends
  use optimization. Symbol inspection shows private-external metadata in the
  individual objects and localization in Swift Build's intermediate object.
  The toolchain marked native backend deprecated. This is diagnostic evidence,
  not permission to switch production backend or expose private types.
- Historical probe sources and object evidence collector are preserved at
  [22d837623cef](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/tree/22d837623cef015532d80922138dc3bcc18e3493/Tools/HTTPLinkReproducer).
  The mini graph is not identical to the full graph. In particular its NIO
  pin is 2.105.0, not H1's 2.105.2.
- H1 main `2cbedd510b15f510c24373ea45ca4fc9cf754cbe` passes the existing
  HTTP-server raw revision in native full qualification and CI #64. H3.1
  does not assume the 0.5.0 linker failure still reproduces on the new graph.

## H3.1 experiment

Use the official 0.5.0 tag
`3e50d9404eb916cd6d030b81af90fdaec73efebc` in place of
`0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9`. No other dependency pin
may change. Preserve SwiftNIO 2.105.2, recorded Core, Swift 6.4.2,
traits: [], release optimization, all SDK sources/tests, and the
shipping CI. The existing H1 graph checker intentionally expects the
old HTTP-server SHA; this diagnostic instead verifies all 29 pins
and actual checkout HEADs in both workspaces after resolution and each
build. Optional originHash is treated as metadata.

The runner edits only the disposable checkout's root manifest and two
lockfiles; none of those changes are committed. Do not run in a working
checkout. Use one fresh build directory for the two optimized fixture
links to limit disk use. Use a quiet native ARM64 macOS 27+ host; the
runner has a conservative 20 GiB free-space minimum (not a measured
upper bound). Prefer the external SSD once available, and allow for
SwiftPM caches on the internal volume. No hosted runners or uploads.

    python3 -I Scripts/probe-h3.py EXACT_RUNNER_SHA "$HOME/MCP-H3-Evidence"

Run logs, graph receipts, source/toolchain provenance and per-product
classification are archived even after ordinary setup/build failure.
The diagnostic checkout retains the build objects for later inspection.
Do not commit or distribute private logs without review.

| Outcome | Interpretation |
| --- | --- |
| LINK_PASS_ONLY | Both optimized executable links and artifact checks passed. Run full qualification on an actual dependency candidate next. |
| LINK_BLOCKED / matching_undefined_metadata | Historical metadata symbol diagnostic reproduced in at least one failing build. Review verbose log and preserved objects, then reduce/report upstream. |
| LINK_BLOCKED / other_build_failure | Inspect actual failure; do not classify as the prior bug. |
| SETUP_OR_INTEGRITY_FAILURE | No valid link disposition from this run; correct setup or inspect graph drift. |

H3.2, if needed: replay the existing standalone ReaderDrop/ReaderCollect
probes on explicit locked graphs; collect producer and consumer symbol
visibility before and after intermediate linking, preserve the native
backend as a diagnostic control only, and prepare a minimal upstream
Swift Build/compiler issue. Determine project ownership from evidence;
do not assert a compiler root cause or invent a fixed release.

If H3.1 links, use a fresh release candidate based on H1 rather than
blindly merging stale #21; update the normal graph checker and docs,
run native Debug/Release SDK + fixture tests and official referees and
Studio Linux ARM64 compile/link CI. Reassess #21 before closing it.
Do not close #13 while platform, dependency and final release gates remain.

## Authoring validation

Python syntax and 8/8 synthetic seed/classification controls passed:
preserve source lock, only substitute the audited HTTP-server pin,
reject wrong HTTP/NIO/Core pins and duplicate identities, classify
matching metadata failure separately from other errors and success.
The native checkout, linker and executable verification have not run.
No release claim follows from a diagnostic pass.
