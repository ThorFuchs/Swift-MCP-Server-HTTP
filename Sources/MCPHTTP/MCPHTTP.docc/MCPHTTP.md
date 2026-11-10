# ``MCPHTTP``

Serve modern MCP POST requests through a bounded, caller-owned HTTP/TLS listener.

``HTTPTransport`` consumes raw bounded bytes and uses the original server admission
account/generation for JSON responses or request-scoped SSE. ``HTTPAccessPolicy``
connects verified resource-server authority. ``AuthorityPolicy`` checks actual bind
context, Host and Origin. ``ToolHeaderMapping`` validates permitted nested declarations
and exact scalar body mirrors. GET and DELETE on the MCP endpoint return 405.

Construction owns no listener. Run owns accepted connections, producer tasks and
acknowledged writers. Shutdown stops this listener and drains its own streams;
parent cancellation joins accepted handlers. Connection, header, body, work and I/O
ceilings remain independent. There are no legacy sessions, GET streams or replay logs.

Prompt peer cancellation before the first head is qualified on macOS27 with the
approved one-file NIO candidate. Each consuming host currently declares that local
candidate explicitly; inheriting the server package's local edge alone was not reliable.
Public packaging requires an approved upstream fix. The native consumer exercises TLS,
Host rejection, injected authorization and joined shutdown through this actual API.

## Topics

### Transport and policy
- ``HTTPTransport``
- ``HTTPAccessPolicy``
- ``AuthorityPolicy``
- ``HTTPAdmission``
- ``ToolHeaderMapping``
