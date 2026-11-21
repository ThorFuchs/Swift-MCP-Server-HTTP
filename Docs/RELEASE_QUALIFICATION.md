# HTTP 1.0 qualification: optimized builds and platform contract (#13)

**Prepared:** 2026-11-21. **Status:** release qualification in progress,
not a declaration that the new optimized jobs have passed.
Record exact PR commit and CI evidence only after it is available.

## Actual published/declaration scope

The HTTP package currently declares **Swift tools 6.4 and macOS 27.0**.
Its public products are `MCPHTTP`, `MCPHTTPAuthorization`,
`MCPHTTPClient` and `MCPClientAuthorization`. The root Core package
separately declares macOS 15, iOS 18 and Linux builds; this does not imply
the same profile for the HTTP product. No HTTP iOS runtime, older macOS
runtime, Linux runtime or Linux HTTP conformance has yet been qualified.

Baseline: [HTTP main `80792825`](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/commit/807928255d4dd6802fae7bb282ede7a02f9a5945).
At baseline, [post-merge CI 44937813368](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/44937813368)
passed macOS 27 debug tests and the server/client 2026-07-28 referee.
The earlier **optimized** server fixture was reported to have a
`NIOHTTPServer.Connection.HTTPProtocol` metadata/link error. This is now
**reproduced**, not just a hypothesis, on the original #13 PR SHA
`aa38b646bc977a7dc746c5a0cdccac8e6349423f` (see evidence below).

## Post-merge Linux fixture follow-up

The [#18 hotfix CI 44943304206](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/44943304206)
on `a2f02d2263baeff176044418f55dbc4754573f1e` proceeded past
the previous HTTP client `Data(buffer:)` compiler error and compiled
the root HTTP package. It next failed compiling the **separate referee
fixture** at
`Tools/Conformance/SwiftFixture/Sources/ConformanceFixture/FixtureRuntime.swift:3`:
`no such module 'CryptoKit'` on Linux (job `136965020798`).

The fixture now imports `CryptoKit` on supported Apple toolchains or
`Crypto` otherwise, and directly declares swift-crypto in its own
package manifest with the `Crypto` target product enabled only for Linux.
It does **not** claim any new platform support, change the HTTP transport
or alter Core's dependency graph. The following CI run must establish
whether both optimized fixtures can now be compiled.

## First #13 qualification results: reproducible failures

[PR #17 CI 44940347042](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/44940347042)
tested commit `aa38b646bc977a7dc746c5a0cdccac8e6349423f`:

- **macOS 27 debug:** successful root tests and both existing server/client
  referees, including the existing declared limitations.
- **macOS 27 optimized:** root HTTP library `swift build -c release`
  **passed**. The next step, the optimized **server** fixture link,
  **failed** with undefined arm64 symbol:
  `type metadata accessor for NIOHTTPServer.NIOHTTPServer.Connection.HTTPProtocol`,
  referenced by `MCPHTTPConnectionHandler.handleConnection`. Therefore
  the optimized client fixture build, optimized XCTest suites and both
  release-mode referee executions **did not run**. Source provenance of the
  linker issue remains unproven: do not assign it to an upstream package
  without isolating whether compiler optimization, our use of the type or
  the pinned `swift-http-server` revision is responsible.
- **Linux Swift 6.4.2:** root/fixture dependency resolution and
  `check-release-graph.py` passed, but root optimized compilation failed
  at `HTTPClientTransport.swift:94` because `Data(buffer: body)` was
  not available on Linux. Later fixture/link checks **did not run**.
- **Evidence hygiene:** `git rev-parse HEAD` in the Linux-container
  script also emitted `fatal: detected dubious ownership`, but did not
  stop the script because it appeared inside an `echo` substitution.
  The result must be an explicit, failure-checked Git query scoped to
  the current checkout, not a global `safe.directory` override.

Follow-up fixes are tracked in the post-merge hotfix PR. Re-run all
gates on its exact SHA before re-evaluating the supported-platform
contract. **No 1.0 release claim is authorized while the optimized
macOS fixture fails to link.**

## Qualified build procedure

`bash Scripts/qualify-release.sh full` (macOS 27) performs explicit
release-mode compilation of the root HTTP package, the server fixture
and the client fixture, then runs optimized SDK and fixture tests.

CI also runs the **actual optimized fixture executables** against both
server and client referees using `MCP_HTTP_FIXTURE_CONFIGURATION=release`
in the existing conformance scripts. All protocol scenarios, extension
coverage and the existing referee timeout remain unchanged. A successful
release build by itself does not substitute for conformance execution.

`bash Scripts/qualify-release.sh build-only` (Ubuntu 24.04 / pinned
Swift 6.4.2 container) is a separate **experimental compile probe** of
all four HTTP library products and both fixture executables. Compile
success is not an advertised Linux HTTP runtime/transport contract. An
unresolved failure is reported as such, never hidden behind an allowed
failure, `continue-on-error` or an invented successful test.

Both paths resolve their **root and fixture graphs independently**, then
`Scripts/check-release-graph.py` verifies matching Core, Swift-JSON,
SwiftNIO, swift-http-server, swift-http-api-proposal and swift-collections
source revisions. Revisions in a committed `Package.resolved` are not
automatically current and must not be substituted for the **actual
run-time resolution**.

## Dependencies and disclosure

| Dependency | Contract at start of #13 | Release concern |
| --- | --- | --- |
| Swift-MCP-Server Core | `branch: "main"` | **Mutable; not suitable for 1.0**; convert after approved Core version in #14 |
| Swift-JSON | aligned with Core at `from: "1.9.0"` | Shared fixture/root revision required |
| swift-http-server | raw SHA `0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9` | Based on 2026-10-08 source; upstream 0.5.0 released 2026-11-04; do not upgrade without tests |
| swift-nio | `from: "2.104.0"`, baseline resolver 2.105.0 | macOS early EOF unresolved in #12 |
| swift-http-api-proposal | `exact: "0.2.0"` | Dependency compatibility still requires proof |
| swift-collections | `exact: "1.6.0"` | 1.7 borrowing iterator change previously incompatible |
| async-http-client | `from: "1.35.0"` | Lock exact resolved SHA for CI evidence |

Swift-MCP-Server-HTTP and the pinned swift-http-server project are
Apache-2.0. This repository includes `LICENSE` and `NOTICE` and
the conformance fixture has `PROVENANCE.md` and `UPSTREAM_LICENSE`.
A complete actual-version transitive-license/SBOM review remains
required for redistribution; the package manifest and the above table
alone are not a legal clearance.

The HTTP-specific cross-repo dependency compatibility / immutable Core
release work is [#14](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/14).
The three existing masked SwiftNIO disconnect tests are independently
tracked by [#12](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/12);
their masking must not be described as runtime success.

## Evidence checklist

- [ ] Exact PR SHA + successful macOS 27 optimized root tests and both fixture links.
- [ ] Exact PR SHA + release-mode server and client conformance, official referee outputs.
- [ ] Linux optimized build result; if red, isolate actual dependency/platform failure.
- [ ] Proven platform promise and explicit non-goals before any 1.0 release.
- [ ] Actual resolved dependency inventory, license/provenance audit.
- [ ] Fixed, immutable Core version and cross-repo consumer (separately #14).
