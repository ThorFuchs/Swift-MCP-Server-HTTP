# Swift-MCP-Server-HTTP

Streamable HTTP transport (`MCPHTTP`) and bearer authorization (`MCPHTTPAuthorization`) for
[Swift-MCP-Server](https://github.com/ThorFuchs/Swift-MCP-Server) (MCP 2026-07-28, macOS 27+, Swift 6.4),
plus the client side: `MCPHTTPClient` (Streamable HTTP for `MCPClient`) and
`MCPClientAuthorization` (OAuth 2.1 for clients, see [Docs/CLIENT_AUTHORIZATION.md](Docs/CLIENT_AUTHORIZATION.md)).

> **Status: pre-release (0.x).** Depends on the core's `main` branch until core 1.0.0.

## Conformance

`Scripts/conformance.sh` runs the official MCP referee (server leg, requirements 2026-07-28)
against `Tools/Conformance/SwiftFixture`. Latest local run (2026-11-10, upstream SwiftNIO 2.105.0):
**37/37 required scenarios passed**; the 3 pending core diagnostics passed; the 10 optional
Tasks diagnostics fail because Tasks is not supported (not scored).

`Scripts/client-conformance.sh` runs the client leg against the client fixture: 37 scenarios,
including 25 `auth/*` scenarios (discovery, client identity, code flow, `iss`, scopes, step-up,
`offline_access` and authorization server migration).

## Known issues

- On macOS, a client disconnect (FIN) while no read is pending is only noticed at the next read
  or write, because upstream SwiftNIO disables early EOF on Darwin. Fix proposed in
  [apple/swift-nio#3783](https://github.com/apple/swift-nio/pull/3783); three tests are marked
  `withKnownIssue` until it ships.
- `swift-http-server` 0.5.0 is selected as a proposed exact release dependency; its macOS optimized-link and lifecycle qualification is still pending. See [release qualification](Docs/RELEASE_QUALIFICATION.md).

## Third-party directory listing

[![M8ven Score](https://m8ven.ai/badge/mcp/thorfuchs-swift-mcp-server-http-ztmm8c?v=05adb4b4f7e0aa9c82d6b34670d22057)](https://m8ven.ai/mcp/thorfuchs-swift-mcp-server-http-ztmm8c?s=readme)

This is a Swift SDK package, not a hosted MCP server. M8ven's third-party directory
score is not a security certification.

## License

Apache License 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
