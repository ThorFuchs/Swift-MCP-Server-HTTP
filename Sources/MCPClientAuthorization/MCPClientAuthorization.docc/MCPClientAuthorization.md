# ``MCPClientAuthorization``

Provide host-controlled OAuth 2.1 authorization for an MCP HTTP client.

## Overview

``OAuthClient`` implements the HTTP client's authorization interface for one
endpoint. It discovers protected-resource and authorization-server metadata,
checks the issuer and resource, selects a client identity, and performs the
authorization code flow with PKCE S256, state and issuer checks.

Configure ``OAuthClientConfiguration`` and supply an
``AuthorizationUserAgent`` to present the authorization request and return
its redirect URL. The host owns the browser or device-specific UI and
redirect handling. The library does not supply that UI.

Client identity is selected using ``ClientIdentity``: an issuer-specific
pre-registration first, a supported client ID metadata document next,
then dynamic registration if configured. Insufficient-scope challenges
can request a bounded step-up; refresh and authorization-server migration
are handled without reusing another issuer's credentials.

Use HTTPS in production. Insecure loopback is an explicit development
option. The caller controls the HTTP client's redirect policy and lifetime.
A host-supplied ``TokenStore`` persists authorization for an endpoint;
``StoredAuthorization`` contains secrets and must be kept in protected
storage such as the Keychain. Without a store, tokens are held in memory.
``InMemoryTokenStore`` is intended for tests and short-lived processes.
Persistence errors propagate to the caller; sign-out deletes the stored
authorization when a store is configured.

Implemented scope is A1–A5. Client credentials, enterprise-managed
authorization, workload identity federation and DPoP (A6) are not
implemented. Neither an authorization server nor a host credential store
is supplied.

## Topics

### Authorization
- ``OAuthClient``
- ``OAuthClientConfiguration``
- ``OAuthClientError``

### Host interaction and identity
- ``AuthorizationUserAgent``
- ``AuthorizationRequest``
- ``ClientIdentity``
- ``PreRegisteredClient``
- ``DynamicRegistration``
- ``TokenEndpointAuthentication``

### Persistence
- ``TokenStore``
- ``StoredAuthorization``
- ``InMemoryTokenStore``
