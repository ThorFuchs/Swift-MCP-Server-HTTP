// SPDX-License-Identifier: Apache-2.0
import Foundation
import BasicContainers
import NIOHTTPServer
import MCPProtocol
import MCPServer

/// Single-slot rendezvous: the producer's sink settles only after actual writing.
/// Pending bytes and the in-flight frame share one finite maximum. Cancellation
/// closes continuations once; no fire-and-forget writer or unowned task exists.
actor HTTPResponseMailbox {
    struct Frame: Sendable { let bytes: Data; let status: Int }
    let maximumBytes: Int
    private var responseStatus = 200
    private var frame: Frame?
    private var reader: CheckedContinuation<Frame?, any Error>?
    private var writer: CheckedContinuation<Void, any Error>?
    private var preparing = false
    private var ended = false
    private var completed = false, failed = false
    private var writeStarted:ContinuousClock.Instant?
    private var completion:CheckedContinuation<Void, any Error>?
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }
    func observeError(_ error:ModernProtocolError) {
        switch error {
        case .standard(.methodNotFound):responseStatus = 404
        case .standard(.internalError):responseStatus = 200
        default:responseStatus = 400
        }
    }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        guard !ended, !preparing, writer == nil, frame == nil, data.count <= maximumBytes else { throw CoreFailure.disconnected }
        preparing = true
        defer { preparing = false }
        // Core supplies exact error metadata from the error it encoded. No
        // response reparsing, independent JSON account or invented report.
        let next = Frame(bytes:data,status:responseStatus)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void, any Error>) in
                guard !ended else { continuation.resume(throwing:CoreFailure.disconnected); return }
                writer = continuation
                if let reader { self.reader = nil; reader.resume(returning:next) }
                else { frame = next }
            }
        } onCancel: { self.cancel() }
    }
    func next() async throws -> Frame? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            if let frame { self.frame = nil; return frame }
            if ended { return nil }
            return try await withCheckedThrowingContinuation { continuation in
                guard reader == nil else { continuation.resume(throwing:CoreFailure.duplicate); return }
                reader = continuation
            }
        } onCancel: { self.cancel() }
    }
    enum Poll:Sendable { case frame(Frame), waiting, finished }
    func poll() throws -> Poll {
        if failed { throw CoreFailure.disconnected }
        if let frame { self.frame = nil; return .frame(frame) }
        return ended ? .finished : .waiting
    }
    func endWrite() { writeStarted = nil }
    func acknowledge() { writeStarted = nil; let c = writer; writer = nil; c?.resume() }
    func beginWrite() { writeStarted = .now }
    func writeOverdue(_ duration:Duration) -> Bool { writeStarted.map { ContinuousClock.now >= $0.advanced(by:duration) } ?? false }
    var isCompleted:Bool { completed || failed }
    func writingFinished() { completed = true; writeStarted = nil; let c = completion; completion = nil; c?.resume() }
    func waitForCompletion() async throws {
        if failed { throw CoreFailure.disconnected }; if completed { return }
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void, any Error>) in completion = c }
    }
    func finish() { ended = true; let c = reader; reader = nil; c?.resume(returning:nil) }
    func fail() { failed = true; let c = completion; completion = nil; c?.resume(throwing:CoreFailure.disconnected); ended = true; frame = nil; let r = reader; reader = nil; let w = writer; writer = nil
        r?.resume(throwing:CoreFailure.disconnected); w?.resume(throwing:CoreFailure.disconnected) }
    // A cancellation handler cannot await an actor. This synchronous signal
    // wakes its owned task via an AsyncStream; see HTTPMailboxCancellation below.
    nonisolated let cancellation = HTTPMailboxCancellation()
    nonisolated func cancel() { cancellation.signal() }
}
/// Sendable cancellation signal only; the request's structured child consumes it.
final class HTTPMailboxCancellation: Sendable {
    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    init() { let pair = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1)); stream = pair.stream; continuation = pair.continuation }
    func signal() { continuation.yield(()); continuation.finish() }
}

extension HTTPStaticResponse {
    /// - Parameter closing: announce `Connection: close`, for responses after which the
    ///   connection cannot carry another request (for example an unread request body).
    func send(_ sender: consuming NIOHTTPServer.ResponseSender, closing: Bool = false) async throws {
        var response = HTTPResponse(status:.init(code:status))
        for field in fields { response.headerFields.append(.init(name:HTTPField.Name(field.name)!, value:field.value)) }
        if closing { response.headerFields[.connection] = "close" }
        response.headerFields[.contentLength] = String(body.count)
        response.headerFields[.cacheControl] = "no-store"
        var bytes = UniqueArray<UInt8>(copying:body)
        try await sender.sendAndFinish(response, buffer:&bytes)
    }
}

/// Actor isolation retains exclusive ownership of the non-Sendable raw writer.
/// It is taken once, then lives only on this actor while the structured child
/// performs I/O. No unchecked Sendable conformance or pointer escape is used.
actor HTTPStreamWriter {
    private var writer:NIOHTTPServer.ResponseSender.Writer?
    init(_ writer:consuming sending NIOHTTPServer.ResponseSender.Writer) { self.writer = consume writer }
    func write(first:HTTPResponseMailbox.Frame,streaming:Bool,mailbox:HTTPResponseMailbox,maximumBytes:Int,ioMilliseconds:Int64,maximumTicks:Int) async throws {
        guard let owned = writer.take() else { throw CoreFailure.duplicate }
        var writer = owned
        var current:HTTPResponseMailbox.Frame? = first
        var ticks = maximumTicks
        let heartbeat = Duration.milliseconds(max(10,min(ioMilliseconds / 2,10_000)))
        var nextHeartbeat = ContinuousClock.now.advanced(by:heartbeat)
        do {
            while let frame = current {
                try Task.checkCancellation()
                var bytes = UniqueArray<UInt8>(copying:streaming ? try SSEFrame.message(Array(frame.bytes),maximumBytes:maximumBytes+8) : Array(frame.bytes))
                await mailbox.beginWrite()
                try await writer.write(buffer:&bytes)
                await mailbox.acknowledge()
                if streaming {
                    waiting: while true {
                        try Task.checkCancellation()
                        switch try await mailbox.poll() {
                        case .frame(let frame): current = frame; break waiting
                        case .finished: current = nil; break waiting
                        case .waiting:
                            guard ticks > 0 else { throw CoreFailure.deadline }; ticks -= 1
                            if ContinuousClock.now >= nextHeartbeat {
                                var comment = UniqueArray<UInt8>(copying:SSEFrame.keepalive())
                                await mailbox.beginWrite(); try await writer.write(buffer:&comment); await mailbox.endWrite()
                                nextHeartbeat = ContinuousClock.now.advanced(by:heartbeat)
                            }
                            try await Task.sleep(for:.milliseconds(10))
                        }
                    }
                } else { current = try await mailbox.next() }
                if !streaming && current != nil { throw CoreFailure.invalidOutput }
            }
            await mailbox.beginWrite()
            var end = UniqueArray<UInt8>()
            try await writer.finish(buffer:&end,finalElement:nil)
            await mailbox.writingFinished()
        } catch { await mailbox.fail(); throw error }
    }
}
