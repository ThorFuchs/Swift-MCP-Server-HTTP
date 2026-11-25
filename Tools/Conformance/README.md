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

The server gate derives its required, Tasks and pending sets from the same
hash-verified Core reference as the client gate. It checks exact and unique scenario
receipts, positive executed checks, known statuses, aggregate summary counts and
not-scored classification. Each of the three separately invoked Skills scenarios has
its own stdout, stderr and process exit. An unexplained nonzero exit, missing or
duplicate receipt, required/extension failure or unexpected skip fails the gate.

Ten Tasks and three Skills scenarios are selected. The pinned referee returns a single
SKIPPED check for tasks-status-notifications pending its subscriptions/listen rewrite;
only that exact documented skip is accepted as KNOWN_UPSTREAM_SKIP, not a pass.
Pending diagnostics must produce valid evidence but their test failures are non-scored.
Warnings are reported separately, preserving the server referee's exit policy.
Use a fresh output directory; plan.json, process-exits.json and, on a passing
validation, summary.json retain the disposition and all raw check receipts remain
available. See [H5.3](../../Docs/Release/H5_SERVER_CONFORMANCE_GATE.md).

The client gate derives the required names from the frozen Core checkout file, verifies
its Git blob ID and root/fixture Core revision, and separately gates one
added-after-release JSON Schema scenario and four Skills extension scenarios.
Six optional A6 authorization extensions are explicitly outside the implemented A1–A5
scope. Each selected client scenario must have a successful referee exit and a nonempty
raw checks receipt, consistent with its printed summary; skipped and INFO checks are
reported, not counted as successes. `plan.json` and `summary.json` record the selection
and outcome. Use a fresh output directory.

Offline controls: `python3 -I Scripts/test-client-conformance-gate.py` and
`python3 -I Scripts/test-server-conformance-gate.py`. H5.3 also replayed the
historical H1 native raw archive against the new server validator. Fresh native
execution of both strengthened gates is pending; historical CI #64 did not run them.
