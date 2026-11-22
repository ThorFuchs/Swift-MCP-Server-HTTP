// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer

/// One waiter per signal. A buffered signal cannot be lost, and cancellation
/// terminates the wait without creating an unowned task or continuation bridge.
private final class CompletedDrainSignal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream
        continuation = pair.continuation
    }

    func signal() {
        continuation.yield(())
        continuation.finish()
    }

    func wait() async throws {
        for await _ in stream {
            try Task.checkCancellation()
            return
        }
        throw CancellationError()
    }
}

private struct CompletedDrainState: Sendable {
    var normalProviderReturns = 0
    var providerFailures = 0
    var sinkAttempts = 0
    var firstFrame: Data?
}

private final class CompletedDrainProbe: Sendable {
    private let state = Mutex(CompletedDrainState())

    func recordNormalReturn() { state.withLock { $0.normalProviderReturns += 1 } }
    func recordProviderFailure() { state.withLock { $0.providerFailures += 1 } }
    func recordSinkAttempt(_ frame: Data) {
        state.withLock {
            $0.sinkAttempts += 1
            if $0.firstFrame == nil { $0.firstFrame = frame }
        }
    }
    var snapshot: CompletedDrainState { state.withLock { $0 } }
}

private enum CompletedDrainFailure: Error { case testDeadline }

private func completedDrainJSON(_ text: String) throws -> JSON {
    try JSONParser().parseWithReport(Array(text.utf8)).result
}

@Suite struct CompletedProviderDrainTests {
    @Test func normalProviderReturnKeepsRequestOwnedUntilFailedEventDrainJoins() async throws {
        let providerReturning = CompletedDrainSignal()
        let sinkEntered = CompletedDrainSignal()
        let failSink = CompletedDrainSignal()
        let probe = CompletedDrainProbe()
        let result = try completedDrainJSON(#"{"resultType":"complete","content":[]}"#)
        let tool = ToolRegistration(
            definition: try completedDrainJSON(#"{"name":"drain","inputSchema":{"type":"object"}}"#)
        ) { _, context in
            do {
                let accepted = try await context.log(.debug, data: .string("buffered event"))
                try #require(accepted)
                // No await or throwing operation follows this checkpoint. It
                // observes the provider's normal return path, not completion
                // of Core's subsequent validation/terminal encoding pipeline.
                probe.recordNormalReturn()
                providerReturning.signal()
                return result
            } catch {
                probe.recordProviderFailure()
                throw error
            }
        }
        let server = try await Server.make(
            info: completedDrainJSON(#"{"name":"completed-provider-drain","version":"1"}"#),
            catalog: ServerCatalog(tools: [tool]),
            cursors: CursorProtector(
                keys: [.init(identifier: ScalarText("key"), material: Data(repeating: 7, count: 32))],
                active: ScalarText("key"), epoch: ScalarText("drain-test"), clock: { 1000 }
            ),
            events: EventPolicy(logRedactor: { $0 })
        )
        let principal = VerifiedPrincipal(
            subject: ScalarText("drain-test"), issuer: ScalarText("issuer"),
            resource: ScalarText("server"), scopes: []
        )
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"drain","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/logLevel":"debug"}}}"#.utf8)

        // The deadline races the entire scenario, including its signal waits.
        // A failed setup therefore cannot leave the test body waiting forever.
        try await withThrowingTaskGroup(of: Void.self) { deadlineGroup in
            deadlineGroup.addTask {
                try await withThrowingTaskGroup(of: Void.self) { requests in
                    requests.addTask {
                        do {
                            try await server.dispatchEvents(
                                request, principal: principal, origin: ScalarText("origin"), mode: .http
                            ) { frame in
                                probe.recordSinkAttempt(frame)
                                sinkEntered.signal()
                                try await failSink.wait()
                                throw CoreFailure.disconnected
                            }
                            Issue.record("A failed event sink must fail the dispatch")
                        } catch {
                            // The existing dispatcher may observe channel.failed
                            // after the producer child, or receive the writer's
                            // disconnected error first. Both are failure paths;
                            // this test qualifies ownership, not error taxonomy.
                            #expect(error as? CoreFailure == .disconnected || error as? CoreFailure == .eventOverflow)
                        }
                    }
                    defer { requests.cancelAll() }

                    try await providerReturning.wait()
                    try await sinkEntered.wait()
                    let pending = await server.activity
                    #expect(probe.snapshot.normalProviderReturns == 1)
                    #expect(probe.snapshot.providerFailures == 0)
                    #expect(pending.active == 1 && pending.requests == 1 && pending.leases == 1)
                    #expect(pending.eventBytes > 0 && pending.bufferedBytes > 0)

                    // No elapsed-time guess: the sink fails only after the
                    // provider's normal return path and retained ownership
                    // have both been observed.
                    failSink.signal()
                    try await requests.waitForAll()
                }
            }
            deadlineGroup.addTask {
                try await Task.sleep(for: .seconds(10))
                throw CompletedDrainFailure.testDeadline
            }
            defer { deadlineGroup.cancelAll() }
            _ = try await deadlineGroup.next()
        }

        let final = probe.snapshot
        #expect(final.normalProviderReturns == 1 && final.providerFailures == 0)
        #expect(final.sinkAttempts == 1, "A failed event write must not retry a terminal response")
        let first = try #require(final.firstFrame)
        let envelope = try JSONParser().parseWithReport(Array(first)).result
        #expect(envelope.objectValue?["method"]?.stringValue == "notifications/message")
        #expect(envelope.objectValue?["result"] == nil)
        let clean = await server.activity
        #expect(clean.active == 0 && clean.queued == 0 && clean.requests == 0 && clean.leases == 0)
        #expect(clean.bufferedBytes == 0 && clean.eventBytes == 0 && clean.subscriptions == 0)
        #expect(clean.inspections == 0 && clean.queuedInspections == 0)
    }
}
