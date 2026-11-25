# Standalone HTTP/TLS example

Requires macOS 27 / SDK 27 / Swift tools 6.4 / language mode 6. From the repository
root, build the included example with:

```sh
swift build --package-path Examples/HTTPServer -c release
```

The example uses the local SDK package path. SwiftNIO 2.105.2 is now the SDK's
released minimum; no local NIO candidate is needed. This example still declares
Core's main branch and the audited raw HTTP-server revision. Resolve and inspect
the actual example graph before running it. The fresh standalone consumer and
immutable release dependency qualification remain open; H1 CI #64 qualified
the separate conformance fixtures, not this exact example build.

ExampleHTTPServer binds127.0.0.1 with `--port 0` by default. Stderr readiness reports
the actual port after lifecycle readiness. `--sse` selects streamed responses;
without it responses use JSON. `--extensions` selects the synthetic host extension.
Host/Origin and port policy are explicit. POST requests require modern metadata,
MCP-Protocol-Version, Mcp-Method and the applicable name/URI/header mirrors.

Plaintext mode explicitly selects a loopback demo principal. For real TLS, supply
`--tls-certificate <PEM> --tls-key <PEM>` and set MCP_EXAMPLE_BEARER_TOKEN to a synthetic
local token of16–4096 bytes. The example checks its SHA256 using a host-owned verifier,
issuer/resource/scopes and finite expiry. Replace this deliberately small verifier
with your production token policy; self-reported clientInfo is never authority.
`--resource` supplies the protected-resource identifier (default https://localhost/mcp).
No credentials, trust-store installation or Keychain mutation are automatic. Public
synthetic PEMs under Tests are test fixtures, never deployment credentials.

The real native example cases verify JSON/SSE, exact progress IDs, a negotiated
supplemental method and nested header mirrors, TLS missing/wrong/valid bearer tokens,
Host/Origin, protocol-only output and SIGTERM with zero owned channels/requests.
Standalone SIGTERM/SIGINT ownership is explicit here; the library embeds cooperatively.
