// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPHTTPClient
import MCPProtocol
import NIOCore
import NIOHTTP1
import NIOPosix

/// The `Authorization` values of every request the challenge server received.
private final class Received: Sendable {
    private let values = Mutex<[String?]>([])
    func append(_ value: String?) { values.withLock { $0.append(value) } }
    var all: [String?] { values.withLock { $0 } }
}

/// Answers `401` with a Bearer challenge, `403 insufficient_scope` for `Bearer weak` and `200`
/// for `Bearer good`; one request per connection.
private func withChallengeServer(_ body: (URL, Received) async throws -> Void) async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .bind(host: "127.0.0.1", port: 0) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel)
            }
        }
    let port = try #require(server.channel.localAddress?.port)
    let received = Received()
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await server.executeThenClose { connections in
                for try await connection in connections { try? await respond(on: connection, received) }
            }
        }
        defer { group.cancelAll() }
        try await body(try #require(URL(string: "http://127.0.0.1:\(port)/mcp")), received)
    }
}

private func respond(on connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, _ received: Received) async throws {
    try await connection.executeThenClose { inbound, outbound in
        var authorization: String?
        for try await part in inbound {
            if case .head(let head) = part { authorization = head.headers.first(name: "Authorization") }
            guard case .end = part else { continue }
            received.append(authorization)
            var headers = HTTPHeaders([("Connection", "close"), ("Content-Type", "application/json")])
            let status: HTTPResponseStatus
            let body: String
            if authorization == "Bearer good" {
                status = .ok; body = #"{"jsonrpc":"2.0","id":1,"result":{}}"#
            } else if authorization == "Bearer weak" {
                status = .forbidden; body = #"{"error":"insufficient_scope"}"#
                headers.add(name: "WWW-Authenticate", value: #"Bearer error="insufficient_scope", scope="write""#)
            } else {
                status = .unauthorized; body = #"{"error":"invalid_token"}"#
                headers.add(name: "WWW-Authenticate", value: #"Bearer error="invalid_token", resource_metadata="http://127.0.0.1/prm""#)
            }
            headers.add(name: "Content-Length", value: "\(body.utf8.count)")
            try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
            try await outbound.write(.body(.byteBuffer(ByteBuffer(string: body))))
            try await outbound.write(.end(nil))
            return
        }
    }
}

/// Hands out `tokens` one per challenge; records the challenges.
private actor ScriptedAuthorizer: HTTPClientAuthorizing {
    private var tokens: [String]
    private var current: String?
    private(set) var challenges: [HTTPAuthorizationChallenge] = []
    init(tokens: [String]) { self.tokens = tokens }

    func authorizationHeaders(for endpoint: URL) -> [(name: String, value: String)] {
        current.map { [("Authorization", "Bearer " + $0)] } ?? []
    }
    func handleChallenge(_ challenge: HTTPAuthorizationChallenge) -> Bool {
        challenges.append(challenge)
        guard !tokens.isEmpty else { return false }
        current = tokens.removeFirst()
        return true
    }
}

private func request() throws -> OutgoingRequest {
    OutgoingRequest(id: try RequestID(.number(JSONNumber(integer: 1))), method: "tools/list", name: nil,
                    body: Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
}

@Suite struct AuthorizationRetry {
    @Test func aChallengeIsAnsweredAndTheRequestSentOnceMore() async throws {
        try await withChallengeServer { url, received in
            let authorizer = ScriptedAuthorizer(tokens: ["good"])
            let replies = Received()
            try await HTTPClientTransport(endpoint: url, timeout: .seconds(10), authorization: authorizer)
                .exchange(try request()) { replies.append(String(decoding: $0, as: UTF8.self)) }
            #expect(received.all == [nil, "Bearer good"])
            #expect(replies.all == [#"{"jsonrpc":"2.0","id":1,"result":{}}"#])
            let challenge = try #require(await authorizer.challenges.first)
            #expect(challenge.status == 401 && challenge.sentAuthorization == nil && challenge.endpoint == url)
            #expect(challenge.wwwAuthenticate == [#"Bearer error="invalid_token", resource_metadata="http://127.0.0.1/prm""#])
        }
    }

    @Test func aRequestIsRetriedAtMostOnce() async throws {
        try await withChallengeServer { url, received in
            // The second token is rejected as well; the transport gives up instead of looping.
            let authorizer = ScriptedAuthorizer(tokens: ["bad", "good"])
            await #expect(throws: HTTPClientTransportError.status(401)) {
                try await HTTPClientTransport(endpoint: url, timeout: .seconds(10), authorization: authorizer).exchange(try request()) { _ in }
            }
            #expect(received.all == [nil, "Bearer bad"])
            #expect(await authorizer.challenges.map(\.sentAuthorization) == [nil])
        }
    }

    @Test func aStepUpMayFollowAFirstAuthorization() async throws {
        try await withChallengeServer { url, received in
            let authorizer = ScriptedAuthorizer(tokens: ["weak", "good"])
            try await HTTPClientTransport(endpoint: url, timeout: .seconds(10), authorization: authorizer).exchange(try request()) { _ in }
            #expect(received.all == [nil, "Bearer weak", "Bearer good"])
            #expect(await authorizer.challenges.map(\.status) == [401, 403])
        }
    }

    @Test func noRetryWithoutNewCredentials() async throws {
        try await withChallengeServer { url, received in
            await #expect(throws: HTTPClientTransportError.status(401)) {
                try await HTTPClientTransport(endpoint: url, timeout: .seconds(10), authorization: ScriptedAuthorizer(tokens: []))
                    .exchange(try request()) { _ in }
            }
            #expect(received.all == [nil])
        }
    }
}
