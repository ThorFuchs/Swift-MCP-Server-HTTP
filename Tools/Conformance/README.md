# Official conformance

`Scripts/conformance.sh` runs the official MCP referee
([`@modelcontextprotocol/conformance`](https://www.npmjs.com/package/@modelcontextprotocol/conformance),
pinned in `package-lock.json`) against `SwiftFixture` over loopback HTTP, using the dated
2026-07-28 requirements: 37 required server scenarios and 13 diagnostics (10 optional Tasks
extension cases, 3 pending core cases). Client requirements are out of scope for a server SDK.

Requirements: Node.js 24 or later, macOS 27, Swift 6.4.

`SwiftFixture` hosts the referee's synthetic "everything server" registrations on the production
products: schema validation, MRTR input rounds, protected state, POST JSON/SSE subscriptions and
catalog changes. It binds only `127.0.0.1:0` and writes a readiness record (nonce, PID, URL) once
the listener is ready. Provenance: [PROVENANCE.md](SwiftFixture/PROVENANCE.md).

Tasks are unsupported; their diagnostics are reported but not scored.
