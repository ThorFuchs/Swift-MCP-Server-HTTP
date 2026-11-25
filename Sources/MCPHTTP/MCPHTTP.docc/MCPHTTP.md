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

Peer-disconnect cancellation before the first head is qualified on native macOS 27
with the released SwiftNIO 2.105.2 dependency. The three native disconnect regressions
are mandatory in Debug and Release. No local dependency edit or fork is required.
The response-head and static-response write deadlines remain a separate qualification
gate; passing the body-write tests does not establish those bounds. Native HTTP tests
exercise TLS, Host rejection, injected authorization and joined shutdown.

## Topics

### Transport and policy
- ``HTTPTransport``
- ``HTTPAccessPolicy``
- ``AuthorityPolicy``
- ``HTTPAdmission``
- ``ToolHeaderMapping``
