# MCPHTTP test plan

Use Swift Testing against the production package. Native listener tests cover
HTTP/TLS, SSE, header mapping, bounded reads, method/media negotiation, authority
and authorization, schema validation, connection admission, cancellation and
shutdown. They share process-global NIO resources and run in a serialized suite;
each case still orchestrates its own concurrent work.

## Response ownership

The [response lifecycle contract](../../Docs/HTTP_RESPONSE_LIFECYCLE.md) separates
provider completion, event drain, HTTP completion and connection teardown.

| Test | Contract |
| --- | --- |
| `normalProviderReturnKeepsRequestOwnedUntilFailedEventDrainJoins` | Hold the public Core event sink with a signal, observe the provider's normal return path and retained ownership, then fail the sink and verify complete cleanup with no second write attempt. This is an in-process boundary test. |
| `nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership` | A finite provider may finish before the real HTTP writer times out. Distinguish normal return, cancellation and stream failure; require cleanup and listener recovery. |
| `nativeHTTPStalledWriterCancelsLiveProviderAndRecovers` | Keep a provider alive behind an unfulfilled cancellation-aware signal. A real stalled writer must cancel that provider and join its work. |
| `nativeHTTPConnectionCeilingRejectsOvershootAndRecovers` | Refused accepted sockets close promptly; strict connection capacity becomes reusable. |

Both stalled-writer cases retain the original frame count, payload size and I/O
deadline. Verify Core and HTTP resource counts before reading the stalled client
or shutting down the listener. Require one timeout, a partial response with one
head and no complete terminal result, and a successful new request on the same
listener with a one-connection ceiling.

Use explicit synchronization for ordering. Time limits bound test completion;
they do not establish that a finite provider is still running. Report admitted
and filtered logging separately. Do not equate every provider error with Swift
task cancellation. An empty test selection is a failed qualification.

## Separate qualifications

Run focused ownership cases in both Debug and Release before the full SDK and
fixture/referee gates. Build the server and client executables: successful root
library compilation does not prove that an optimized downstream executable links.

The existing Darwin early-EOF known-issue cases remain a separate dependency
qualification. A known issue or an in-process sink test is not evidence of a
passing native peer-disconnect case. Response-head and static-response write
deadlines also need dedicated native tests; the current body-stall cases do not
prove those paths.

Execution results belong in CI and generated local logs, not hand-maintained
counts or historical receipt paths in this test plan.

