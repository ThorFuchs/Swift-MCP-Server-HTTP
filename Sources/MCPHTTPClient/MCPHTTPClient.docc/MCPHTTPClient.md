# ``MCPHTTPClient``

Connect a Core MCP client to a Streamable HTTP endpoint.

## Overview

``HTTPClientTransport`` implements the Core client transport for MCP 2026-07-28.
It sends a POST for each exchange, includes the protocol and request-mirroring
headers, and delivers a JSON message or the data messages from a server-sent
event stream. The calling task owns the exchange; cancellation closes the
stream. The message-size limit applies to JSON bodies and individual SSE
messages. The configured exchange timeout includes listen streams.

Use an HTTPS endpoint for production. The host chooses the AsyncHTTPClient
instance and its TLS, redirect, proxy and connection settings; the library
does not shut down a caller-supplied HTTP client.

``HTTPClientAuthorizing`` is the host's credential/challenge boundary. The
transport obtains authorization headers before sending a request and passes
401/403 challenges to that value. When it obtains replacement credentials,
the transport retries at most once per status (one 401 retry and one 403 retry).
The challenge contains the authorization value actually sent; treat it as
sensitive and do not log it. The sibling MCPClientAuthorization product
provides an OAuth implementation.

This is a transport, not an authorization server or a legacy session
implementation. The HTTP package is pre-release. macOS 27 is the declared
platform floor; the current Linux evidence is compile/link only.

## Topics

### Transport
- ``HTTPClientTransport``
- ``HTTPClientTransportError``

### Credential integration
- ``HTTPClientAuthorizing``
- ``HTTPAuthorizationChallenge``
