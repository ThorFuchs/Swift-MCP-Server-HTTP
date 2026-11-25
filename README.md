# Swift-MCP-Server-HTTP

Streamable HTTP transport (`MCPHTTP`) and bearer authorization (`MCPHTTPAuthorization`) for
[Swift-MCP-Server](https://github.com/ThorFuchs/Swift-MCP-Server) (MCP 2026-07-28, macOS 27+, Swift 6.4),
plus the client side: `MCPHTTPClient` (Streamable HTTP for `MCPClient`) and
`MCPClientAuthorization` (OAuth 2.1 for clients, see [Docs/CLIENT_AUTHORIZATION.md](Docs/CLIENT_AUTHORIZATION.md)).

> **Status: pre-release (0.x).** Depends on the core's `main` branch until core 1.0.0.

## Conformance

`Scripts/conformance.sh` runs the official MCP referee (server leg, requirements 2026-07-28)
against `Tools/Conformance/SwiftFixture`. The H1 integration
[CI run #64](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45604079743) on 2026-11-25
reported 37/37 required server scenarios in Debug and Release with SwiftNIO
2.105.2. The independent H5.3 replay of the earlier H1 native archive verified
**37/37 required, 12/13 extensions passed plus one known upstream skip, and
3/3 pending diagnostics passed** in both configurations. A Debug SHOULD
warning remains visible. The client CI logs show all 32 frozen required
scenarios, one additional JSON Schema diagnostic, and four Skills extensions
passed in both modes; six optional A6 scenarios are outside the implemented
client scope. Neither a scenario pass nor a green process proves execution of
every raw check. See the [native qualification review](Docs/Release/H1_SWIFTNIO_RELEASE_QUALIFICATION.md)
and [H5.3 server gate](Docs/Release/H5_SERVER_CONFORMANCE_GATE.md).
The strengthened gates are implemented but await a fresh native run.
The same CI passed Linux ARM64 optimized compile/link; Linux runtime, AMD64
and HTTP iOS support are not qualified.

`Scripts/client-conformance.sh` runs the client leg against the client fixture: 37 scenarios,
including 25 `auth/*` scenarios (discovery, client identity, code flow, `iss`, scopes, step-up,
`offline_access` and authorization server migration).

## Documentation

- `MCPHTTP`: server transport and host access policy
- `MCPHTTPAuthorization`: resource-server verification and metadata
- `MCPHTTPClient`: client transport and credential integration
- `MCPClientAuthorization`: [OAuth client setup and behavior](Docs/CLIENT_AUTHORIZATION.md)

Each public product has a DocC catalog. Build all four archives with
`bash Scripts/build-docs.sh` on the supported Swift toolchain.
The SDK and its Core dependency remain pre-release.

## Known issues

- SwiftNIO 2.105.2 is the minimum required version: it contains the early EOF fix for
  macOS TCP connections ([apple/swift-nio#3783](https://github.com/apple/swift-nio/pull/3783)).
  The three native disconnect tests are mandatory, not known-issue allowances.
  See [HTTP #12](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/12)
  for the independent release qualification; the earlier diagnostic proof is not a release result.
- `swift-http-server` is pinned to a revision (pre-release dependency);
  the official 0.5.0 optimized-link qualification remains open.
- Response-head and static-response write deadline qualification remains open
  ([#25](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/25)).

## Third-party directory listing

[![M8ven Score](https://m8ven.ai/badge/mcp/thorfuchs-swift-mcp-server-http-ztmm8c?v=05adb4b4f7e0aa9c82d6b34670d22057)](https://m8ven.ai/mcp/thorfuchs-swift-mcp-server-http-ztmm8c?s=readme)

This is a Swift SDK package, not a hosted MCP server. M8ven's third-party directory
score is not a security certification.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
