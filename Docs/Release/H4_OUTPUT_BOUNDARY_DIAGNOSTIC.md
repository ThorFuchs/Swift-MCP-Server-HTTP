# H4.1 — Response write boundary diagnostic (#25)

Status: source audit and cooperative RED/GREEN test scaffold. No native
compile or test result yet. Diagnostic branch only; do not merge or use
as the production deadline correction.

## Scope and independence

Base: H1/H2 main `2cbedd510b15f510c24373ea45ca4fc9cf754cbe`.
Keep the existing HTTP-server revision, SwiftNIO 2.105.2, Core revision,
lockfiles, protocol requirements and existing tests unchanged. H3 can
independently replace the dependency later; repeat the final H4 tests
on whichever graph ships.

## Source audit

| Path | Actual suspension boundary | Current watchdog coverage |
| --- | --- | --- |
| Streaming/JSON first response | HTTPTransport: sender.send(head) in request parent | Missing: no beginWrite, parent has not reached waitForCompletion |
| Frame body | HTTPStreamWriter: writer.write(buffer:) in owned output child | beginWrite through acknowledge |
| SSE heartbeat | writer.write(buffer:) in output child | beginWrite through endWrite |
| Final framing | writer.finish(buffer:finalElement:) in output child | beginWrite through writingFinished |
| Protected resource metadata | HTTPStaticResponse.send -> sender.sendAndFinish | Outside mailbox |
| Notification rejection | HTTPStaticResponse(status:400).send -> sendAndFinish | Outside mailbox |
| Admission, authority, header, auth rejections | HTTPStaticResponse.send(closing:unread) -> sendAndFinish | Outside mailbox |

At the selected upstream source 0b8f1691..., ResponseSender.send awaits
NIOAsyncChannelOutboundWriter.write(.head(response)); sendAndFinish
awaits one write(contentsOf:) containing head/body/end. The latter sets
finishedWriting only on success. Both upstream sender and writer are
noncopyable and explicitly unavailable for Sendable conformance.

The existing mailbox monitor can fail the mailbox, but cannot by that
act cancel a parent still suspended before its output child starts.
Also audit cancellation of waitForCompletion itself: the continuation
currently depends on the existing completion/failure paths. None of
these source observations proves an observed production hang.

## H4.1 cooperative test seam

An internal per-transport checkpoint, installed only before run, defaults
to nil. No public API, global mutable switch or unsafe Sendable escape.
The diagnostic inserts awaits just before the output API calls; the
head/metadata/notification checkpoints precede sender consumption,
whereas rejection follows its existing sender take. These are cooperative
SDK boundaries, **not actual NIO writer-suspension instrumentation**.

Two existing native-listener-suite tests hold the first selected checkpoint:
normal RPC response head and pre-body static rejection. The gate uses a
cancellation-aware AsyncStream; its normal release is reserved for failure
cleanup and throws instead of sending the response. The test establishes
entry before asserting one write timeout, actual checkpoint-task cancellation
and exit, all Core/HTTP owner counters zero, and same-listener recovery
with the one-connection ceiling. No peer read/close or listener shutdown
is used to achieve those assertions. The existing I/O configuration accepts
500 ms; 5 s test watchdogs bound observation, not the shipping I/O contract.
No existing assertion or production timeout is changed.

The baseline hypothesis is RED: the output checkpoint is not currently
covered by the timeout supervisor. Compile errors, failure to enter the
selected gate, or failure during cleanup are not valid RED evidence.
Inspect the H4_CHECKPOINT receipt before concluding. Do not run the
full release matrix on this deliberately diagnostic branch.

### Native focused run (fresh checkout, quiet Mac, no hosted jobs)

    swift test -c debug -j 2 --force-resolved-versions --filter nativeHTTPHeadCheckpointCancellationAndRecovery
    swift test -c debug -j 2 --force-resolved-versions --filter nativeHTTPRejectionCheckpointCancellationAndRecovery
    swift test -c release -j 2 --force-resolved-versions --filter nativeHTTPHeadCheckpointCancellationAndRecovery
    swift test -c release -j 2 --force-resolved-versions --filter nativeHTTPRejectionCheckpointCancellationAndRecovery

Capture source SHA, toolchain, both locks and actual dependency revisions;
run one case at a time and preserve nonzero exits. Never mark a skipped or
unexecuted test as a successful reproduction.

## H4.2 proposed design, not implemented

Transfer the consuming sender into a single actor-owned output operation
before the first actual head/static write, following the existing
HTTPStreamWriter ownership pattern. The actor takes it exactly once,
holds the writer locally while performing head/body/heartbeat/end, and
never transfers raw move-only values into escaping closures. The supervisor
captures only Sendable references; timeout elects failure once, cancels
and joins the exact operation and producer, settles mailbox continuations
and aborts the exchange. Keep the existing streaming per-write deadline
and independent Core request budget (not a fixed timeout for the whole SSE
subscription). For static writes use an equivalent bounded operation with
the configured I/O budget; preserve status, headers, length, unread-body
close behavior and at-most-one terminal attempt. No fallback response
after ownership has been consumed or output attempted.

Prove the implementation with deterministic cooperative gates first.
The acceptance gate in #25 also requires an actual native NIO outbound
suspension proof: bounded slow-reader/backpressure setup, explicit
observation of the exact head/static write being held, cancellation/join
and no second terminal write, including metadata/rejection/notification
and TLS as appropriate. Merely sleeping while a socket is unread or
blocking this diagnostic hook is insufficient. A small static response
can fit in kernel buffers; use an upstream-supported instrumentation
boundary or bounded pressure scenario with observed writer suspension.
Do not silently expose upstream private state, patch a dependency into
the release graph, or declare native backpressure proven by this seam.

Then qualify all existing native tests, both optimized fixture links,
both referee roles in Debug/Release and Linux compile/link on the
immutable integration graph. Remove diagnostic-only instrumentation or
review its final internal form separately. No H4 gate is closed here.
