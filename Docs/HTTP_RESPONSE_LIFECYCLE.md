# HTTP response lifecycle

## Ownership contract

Provider completion, response drain and connection teardown are separate events.
Each layer retains its resources until its own work settles and its children join.

| Owner | Responsibility | Completion boundary |
| --- | --- | --- |
| Provider | Compute a result and emit request events | The provider returns or throws |
| Core dispatch | Admit the request, retain its catalog lease, coordinate provider and event writer | Both structured children settle and join |
| Event channel | Bound queued, preparing and in-flight event bytes; preserve event order | Accepted frames drain to the sink, or failed delivery drops them and releases their reservations |
| HTTP response | Own response head, body, final framing and failure teardown | Its output child finishes or is cancelled and joined |
| Connection handler | Retain the accepted connection and enforce its ceiling | The upstream request loop and channel lifetime end |

`RequestContext.log(...) == true` means that the event was admitted to the bounded
Core channel. Provider completion can therefore precede event drain. A provider
that has already returned normally has no live callback left to cancel when a
later write fails.

Core dispatch retains its admission permit and request ownership while the event
sink is pending. A failed sink must terminate dispatch, release event and request
reservations, and suppress any later terminal write attempt. A still-running
provider must observe cancellation or channel failure and be joined. Host
callbacks remain responsible for cooperating with cancellation.

The terminal coordinator elects one terminal response attempt. Its elected
`complete` outcome describes the chosen response, without asserting successful
delivery. A failed write must never elect or send a replacement response. Once
the HTTP response head has been sent, failure aborts that exchange.

The Core activity snapshot and HTTP activity snapshot measure different owners.
Core counters can reach zero before HTTP final framing and connection teardown
finish. Cleanup tests must inspect the owners relevant to the scenario. A local
write completion also cannot establish that the client application consumed the
response.

## Timeout ownership

A response write deadline must cover every potentially suspended output step:
response head, body, heartbeat and final framing. The task that observes timeout
must be able to cancel and join the task performing that I/O. Setting a timeout
flag or completing an unrelated child does not interrupt a parent suspended in a
raw write.

The streaming body path currently uses an output child plus mailbox completion:
the watchdog fails the mailbox, the parent observes that failure, and scope exit
cancels and joins output. The following coverage remains to be qualified:

- The initial `ResponseSender.send(head)` occurs in the parent before the output
  child and before `waitForCompletion()`. That upstream operation can suspend in
  its outbound writer. `mailbox.fail()` alone cannot wake this await. Core's
  deadline can end the producer without being observed by this parent yet.
- Static responses use `sendAndFinish` outside that mailbox/watchdog path.
  Metadata and admission rejection paths therefore need their own explicit
  output bound. Upstream connection idle and request-body timers are phase
  specific; they do not establish a response-write deadline for these paths.

A focused correction should move head, body and end into one owned output task,
with exclusive ownership of the noncopyable sender/writer. Static output should
obtain the same cancellation-and-join guarantee. Native blocked-head and blocked-
static-response tests must establish the gap and qualify the chosen correction.
This is a separate investigation from a body-write test whose provider may have
already completed.

## Required behavioral tests

1. Hold a provider active, stall output, and verify interruption, joined teardown,
   no second terminal attempt, and recovered capacity.
2. Let a provider reach its normal return path while its event sink is held.
   Verify retained Core ownership; then fail the sink and verify complete cleanup
   with zero provider failures and one failed delivery attempt.
3. Drain accepted events successfully and verify one terminal response follows
   them in order.
4. Stall response-head and static-response writes and verify the configured I/O
   deadline closes the exchange and releases the corresponding owners.
5. Qualify peer disconnect before a response head separately against the selected
   upstream dependency revision, including TLS and repeated reconnection.

Use explicit state barriers for ordering. Time limits bound test completion;
they should not decide whether the provider is still running. Build executable
consumers and run the native failure cases in both Debug and Release.
