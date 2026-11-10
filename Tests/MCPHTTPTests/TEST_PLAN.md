# MCPHTTP test plan

Real HTTP/TLS and SSE, standard/custom header mirroring/sentinel/scalar cases, raw bounded reader, invalid methods/media/Accept, GET/DELETE 405, no session/replay, Host/Origin/proxy checks, slow clients/accepted channel cancellation.

Use real Swift Testing @Test/#expect after implementing behavior. Parameterize adversarial variants; orchestrate races with explicit synchronization rather than timing sleeps. In-process helpers do not substitute for actual I/O where transport ownership is the claim. Record source paths and gate receipts. No passing empty tests or fixture production flags.
# Current execution evidence

The actual listener cases in NativeListenerTests.swift run against production
source linked into the scoped native harness, with real HTTP/1.1/TLS sockets.
See [current outcomes](../../Docs/Evidence/HTTP/cases.json). Thirty listener
functions include real Host/Origin, mirrors, admission/time/body/header limits,
auth, input/output schema checks, JSON/SSE, stalled writes, cancellation and
shutdown ownership. One strict Darwin pre-head peer cancellation test fails and
is retained; the HTTP target/test guard remains. No simulated mode or skipped
test is counted as a transport pass. The full suite preserves all133stdio tests.

