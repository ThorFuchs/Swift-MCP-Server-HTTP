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
`NIOHTTPServer.Connection.HTTPProtocol` metadata/link error. That report
is a **hypothesis** pending fresh reproduction.

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
