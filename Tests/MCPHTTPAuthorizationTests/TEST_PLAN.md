# MCPHTTPAuthorization test plan

Metadata routes/resource HTTPS validation, Bearer escaping, invalid/expired/wrong issuer/resource tokens, scopes, principal separation/state binding, explicit loopback policy and known sentinel-secret redaction.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.
# Current execution evidence

ProtectedResourceMetadata/HTTPAuthorizationPolicy and their real TLS listener
cases are implemented. MetadataTests.swift checks bounded unsafe configurations
and scope-hint overflow remains a denial. Real listener tests cover metadata,
trust, token failures/scopes/principal separation, finite verifier deadlines and
shutdown joining. [Exact cases and commands](../../Docs/Evidence/HTTP/summary.json).
The authorization guard is removed after substantive behavior passes. Aggregate
Q08 remains blocked by HTTP peer lifetime and full consumer prerequisites.

