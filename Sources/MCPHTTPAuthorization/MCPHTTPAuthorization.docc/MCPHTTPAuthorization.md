# ``MCPHTTPAuthorization``

Protect an MCP HTTP resource using host-owned verification and immutable metadata.

Implement ``TokenVerifier`` in the host. ``AuthorizationMiddleware`` checks verified
issuer, resource audience, expiry and ``ScopePolicy`` requirements.
``HTTPAuthorizationPolicy`` provides bounded Bearer challenges and
``ProtectedResourceMetadata`` supplies the exact protected-resource GET route to HTTP.
Credentials never enter provider contexts, logs or continuation state.

The host owns TLS credentials, verifier cryptography and replay-sensitive application
policy. Missing credentials, invalid verification and insufficient scopes deny access
before effects. Operational verifier failures are sanitized and bounded by cancellation.
Loopback development is an explicit configuration. This resource-server
module does not supply an authorization server; the sibling
MCPClientAuthorization product implements client-side OAuth.

The full consumer uses synthetic TLS inputs and a verifier, checks missing/invalid
bearer challenges and observes the verified principal in a typed provider. Native
HTTP tests separately cover scope, expiry, audience, cancellation and redaction.
Current native qualification uses the released SwiftNIO 2.105.2 dependency.
The HTTP package remains pre-release; the final Core/HTTP dependency and
release-platform qualification are separate.

## Topics

### Resource-server authorization
- ``TokenVerifier``
- ``AuthorizationMiddleware``
- ``HTTPAuthorizationPolicy``
- ``ProtectedResourceMetadata``
- ``ScopePolicy``
