# External HTTP ownership/link probes

These are diagnostic consumer/link probes. A passing miniature product is not
proof that the original executable failure is fixed; the conformance server
remains the primary integration reproducer.

[CI 45073773028](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45073773028)
compiled and linked all four Debug products and the Release ConnectionTransfer
control. The three other Release products reproduced the expected undefined
metadata accessors with Swift Build. The original export verifier incorrectly
searched mangled symbols for unabbreviated function names; those five verification
failures were harness errors. Verification now searches demangled defined exports.
Do not reinterpret the three actual Release link failures as verifier errors.

These four small products isolate use of public `NIOHTTPServer` noncopyable values
from MCP, authentication, admission state, and live networking. Each is an explicit
dynamic library so its public functions are exported and linked on macOS. An
ordinary automatic library target can finish compilation without exercising the
failing link. No listener is started and no binary needs to be executed.

| Product | Question |
| --- | --- |
| `ConnectionTransferProbe` | Can a downstream function always transfer Connection to a consuming callback? |
| `ConnectionDropProbe` | Does an early throw before transfer cause a reference to private Connection metadata? |
| `ReaderDropProbe` | Does destruction of a Reader without reading require its private State metadata? |
| `ReaderCollectProbe` | Does the SDK's bounded read loop reproduce the missing Reader State/Reading accessors? |

The callback in the Connection transfer control is deliberately simpler than the
upstream default handler. If the original failure reproduces only with that handler,
retain the original fixture and reduce from it; do not treat a green control as a fix.

## First run on one Mac

From this directory, use a terminal or an SSH shell on the Mac. Run after the other
parity/CI jobs have finished, to keep the experiment easy to interpret.

```bash
bash run.sh published swiftbuild
```

The script makes a fresh package copy, records the host and resolved dependencies,
and compiles/links all four products in Debug and Release. Every exit status and
verbose build log is retained in the printed `evidence` directory. A zero build
exit code is additionally checked against the actual `.dylib` and an exported
probe function. Missing artifacts or symbols make verification fail. No compiler
flags are weakened. A compilation failure is a probe setup problem until its
diagnostics are reviewed; it is not evidence of the original undefined-symbol
failure. `matching_undefined_metadata` requires the original metadata names in
an actual undefined-symbol diagnostic. A completely green miniature run is labeled
`all_probe_products_linked_not_a_fix_claim`.

If the candidate reproduces the **same** missing metadata symbols, compare the old
upstream revision using otherwise identical inputs:

```bash
bash run.sh baseline swiftbuild
```

Only after that, use the second build backend to separate Swift Build invocation
or linkage from target/toolchain code generation:

```bash
bash run.sh published native "$HOME/MCP-Link-Probes" release
```

The original macOS CI output uses Swift Build's `.build/out` and
`Intermediates.noindex` layout. Both backend names are documented SwiftPM options.
Record `swift build --help` if the selected toolchain rejects a backend. These are
diagnostic comparisons, not a proposal to silently change the release build system.

The committed `Package.resolved` preserves the original miniature Swift Build
graph. A published run seeds that file and fails if resolution or building changes
it. The baseline variant intentionally changes the HTTP-server revision before
resolution and records its resulting graph separately. The optional final argument
`release` builds only Release; the default `both` builds Debug and Release.

The miniature graph has 24 pins; the full MCP fixture has 29. HTTP APIs 0.2.0,
HTTP-server 0.5.0, NIO 2.105.0 and Collections 1.6.0 match. The original miniature
uses Crypto 5.1.2, swift-system 1.9.0 and swift-log 1.17.2, while the original full
fixture uses 4.5.2, 1.8.1 and 1.17.0 respectively. The backend comparison must keep
each graph unchanged relative to its own prior run. It does not claim the miniature
and full fixture have identical dependency graphs.

## Evidence needed from a matching failure

Keep the verbose failing log, all `NIOHTTPServer` and probe objects, and the generated
link file list. Inspect the missing symbol with `xcrun nm -m` and
`xcrun swift-demangle` (or `swift demangle` if that toolchain does not expose the
standalone demangler). Determine whether the referenced accessor is absent,
defined locally, or defined globally but omitted from the link inputs. The
distinction decides whether this is code generation/visibility or missing objects.
Do not make private upstream types public just to force a green consumer.

If these four small probes all link, the next reduction is a concrete request
handler around `ReaderCollectProbe` and the original server fixture. Do not add
untested `@_optimize(none)`, library-evolution flags, Sendable escapes or skipped
release tests to the shipping package.

## Source findings

- HTTP PR #20 and #21 are independent branches from the same main commit; #21
  does not contain #20's always-transfer connection path.
- The upstream Connection declaration is unchanged between raw revision
  `0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9` and the 0.5.0 tag at
  `3e50d9404eb916cd6d030b81af90fdaec73efebc`.
- Upstream commit `03099aaf3581c3deff6eaeef1d92ec70a8cb5fea` replaces the Reader's
  reference state with an internal noncopyable `State` enum containing a nested
  noncopyable `Reading` struct. These are the additional accessor names seen in
  #21's optimized external consumer.
- Neither relevant source file uses `@inlinable`. The exact mechanism of the
  downstream references must be established from emitted objects or IR, rather
  than assumed to be an explicit inlining annotation error.

Relevant immutable sources:

- [Reader state change](https://github.com/swift-server/swift-http-server/commit/03099aaf3581c3deff6eaeef1d92ec70a8cb5fea)
- [0.5.0 Reader](https://github.com/swift-server/swift-http-server/blob/3e50d9404eb916cd6d030b81af90fdaec73efebc/Sources/NIOHTTPServer/NIOHTTPServerReader.swift)
- [0.5.0 Connection](https://github.com/swift-server/swift-http-server/blob/3e50d9404eb916cd6d030b81af90fdaec73efebc/Sources/NIOHTTPServer/NIOHTTPServer%2BConnection.swift)
- [Failing external executable CI job](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45056947582/job/137314161577)
- [SwiftPM backend documentation](https://github.com/swiftlang/swift-package-manager/blob/767391fa8ed575c94a8719ec13580287bdb2b323/Sources/PackageManagerDocs/Documentation.docc/SwiftBuildPreview.md)

Swift compiler issue [#88131](https://github.com/swiftlang/swift/issues/88131) is an
analogous report of external optimized code referencing an internal type's missing
metadata accessor. Its maintainers identify a compiler problem in that case.
It is useful investigation context, **not evidence that this HTTP failure has the
same root cause**.
