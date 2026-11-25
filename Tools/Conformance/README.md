# Official conformance

`Scripts/conformance.sh` runs the official MCP referee
([`@modelcontextprotocol/conformance`](https://www.npmjs.com/package/@modelcontextprotocol/conformance),
pinned in `package-lock.json`) against `SwiftFixture` over loopback HTTP, using the dated
2026-07-28 requirements. The frozen reference lists 37 server and 32 client required
scenarios. The HTTP SDK implements both roles; run `Scripts/client-conformance.sh` for
the client fixture. The pinned referee is 0.2.0-alpha.12; the frozen requirement anchor
is alpha.10, not the current scenario catalog.

Requirements: Node.js 24 or later, macOS 27, Swift 6.4.

`SwiftFixture` hosts the referee's synthetic "everything server" registrations on the production
products: schema validation, MRTR input rounds, protected state, POST JSON/SSE subscriptions and
catalog changes. It binds only `127.0.0.1:0` and writes a readiness record (nonce, PID, URL) once
the listener is ready. Provenance: [PROVENANCE.md](SwiftFixture/PROVENANCE.md).

The server additionally gates ten Tasks and three Skills extension scenarios.
The upstream tasks-status-notifications check is skipped; three separate pending server
diagnostics are not scored. Do not interpret an extension scenario pass as execution of
every raw check.

The client gate derives the required names from the frozen Core checkout file, verifies
its Git blob ID and root/fixture Core revision, and separately gates one
added-after-release JSON Schema scenario and four Skills extension scenarios.
Six optional A6 authorization extensions are explicitly outside the implemented A1–A5
scope. Each selected client scenario must have a successful referee exit and a nonempty
raw checks receipt, consistent with its printed summary; skipped and INFO checks are
reported, not counted as successes. `plan.json` and `summary.json` record the selection
and outcome. Use a fresh output directory.

The new client gate has offline controls (`python3 -I Scripts/test-client-conformance-gate.py`).
Native qualification of the revised gate is pending; historical CI #64 did not run it.
