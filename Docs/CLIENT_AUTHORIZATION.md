# Client authorization (`MCPClientAuthorization`)

OAuth 2.1 for MCP clients over HTTP, following ADR-0006 in the core repository. Slices A1–A3
are implemented: discovery, client identity and the authorization code flow.

## Setup

```swift
let configuration = OAuthClientConfiguration(
    identity: ClientIdentity(
        metadataDocument: URL(string: "https://app.example/oauth/client.json"),   // used when the server supports it
        dynamicRegistration: DynamicRegistration(clientName: "Example App")),     // fallback
    redirectURI: URL(string: "http://127.0.0.1:53682/callback")!)
let oauth = OAuthClient(endpoint: endpoint, configuration: configuration, userAgent: browser)
let client = Client(transport: HTTPClientTransport(endpoint: endpoint, authorization: oauth))
```

The host supplies the `AuthorizationUserAgent`, which opens the authorization URL (for example with
`ASWebAuthenticationSession` or a loopback listener) and returns the redirect it received.

## Behavior

- **Transport.** `HTTPClientTransport` asks its `HTTPClientAuthorizing` value for headers before
  each request. On `401` or `403` it passes the challenge (status, `WWW-Authenticate`, the
  credentials sent) to the handler and sends the request once more if the handler obtained new
  credentials; never a second time.
- **A1 Discovery.** Protected resource metadata (RFC 9728) comes from `resource_metadata` in the
  challenge, else from the path-inserted well-known URL, then the root one. The published `resource`
  must cover the endpoint (same scheme, host and port; a parent path on a segment boundary). It is
  sent unchanged as `resource`. Authorization server metadata comes from the RFC 8414 and OpenID
  Connect well-known URLs (path-inserted for issuers with a path). Its `issuer` must equal the
  issuer exactly, and it must offer PKCE `S256`.
- **A2 Client identity.** The client uses a pre-registered client for the issuer first. Next it
  uses a client ID metadata document, when the server sets `client_id_metadata_document_supported`.
  Last it falls back to dynamic client registration (RFC 7591, with `application_type`).
  The token endpoint authentication method is the one the registration assigned. Otherwise it is
  `none` without a secret, else `client_secret_basic` unless the server lists only
  `client_secret_post`.
- **A3 Code flow.** Each authorization request gets a fresh PKCE `S256` verifier and `state`, and
  carries `resource` and `scope`. `scope` comes from the challenge, else from every scope the
  resource lists, else it is omitted. Before the code is sent anywhere, the client checks the
  redirect: the redirect URI must match, `error` aborts, `state` must match, and `iss` must equal
  the issuer by exact string. `iss` is required when the server advertises it (RFC 9207). Only
  `Bearer` tokens are accepted.
- **Security.** Every URL must be `https`. `allowsInsecureLoopback` permits `http` to loopback
  hosts, for development only. Response bodies are bounded (`maximumDocumentBytes`, 64 KiB by
  default). All JSON goes through Swift-JSON. Tokens, codes and secrets are never logged.
- **Concurrency.** Concurrent challenges share one authorization. A request rejected with an
  older token is retried with the current one without a new flow.

## Not yet implemented

- A4: `403 insufficient_scope` step-up with a retry limit, `offline_access` and refresh tokens.
- A5: authorization server migration and a host `TokenStore`; tokens live in memory today.
- A6: client credentials, enterprise-managed authorization, workload identity federation and DPoP.
- The `OAuthClient` uses the given `HTTPClient` for metadata, registration and token requests and
  follows its redirect configuration.

## Conformance

`Scripts/client-conformance.sh` runs 20 `auth/*` referee scenarios:

- `metadata-default` and `metadata-var1`–`var3`
- `metadata-issuer-mismatch` and `resource-mismatch`
- `basic-cimd` and `pre-registration`
- `token-endpoint-auth-basic`, `-post` and `-none`
- six `iss-*` scenarios
- `scope-from-www-authenticate`, `scope-from-scopes-supported` and `scope-omitted-when-undefined`
