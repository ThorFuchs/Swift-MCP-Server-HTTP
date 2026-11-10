# Repository instructions

Process: [ADR-0001](Docs/ADR/0001-lean-process.md). Branch → PR → CI → squash merge.

This package adds the Streamable HTTP transport (`MCPHTTP`) and OAuth-style bearer
authorization (`MCPHTTPAuthorization`) to the core `Swift-MCP-Server` package. Protocol,
runtime and stdio code belong in the core repository, not here.

Use Swift tools 6.4, language mode 6, macOS/SDK 27+. No package-owned unsafe compiler flags,
retroactive Sendable escapes, silent validation skips, network schema fetches or detached unowned
tasks. Never bootstrap process-global logging/metrics, install signals or own host credentials
from a reusable library. Use upstream SwiftNIO; do not vendor or patch it.

Add Swift Testing tests for changed behaviour including race/failure paths. Run `Scripts/test.sh`
and, for wire changes, `Scripts/conformance.sh` before opening a PR; report results truthfully.
Never commit machine paths, credentials or generated evidence. Push, tag and release only on
maintainer request.
