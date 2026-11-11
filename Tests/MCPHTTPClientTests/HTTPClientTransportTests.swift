// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPHTTP
@testable import MCPHTTPClient
import MCPProtocol
import MCPServer

private func json(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }
private let anonymous = VerifiedPrincipal(subject: ScalarText("anonymous"), issuer: ScalarText("development"), resource: ScalarText("loopback"), scopes: [])
private func text(_ value: String) throws -> JSON {
    .object(try JSONObject(members: [JSONMember("resultType", value: .string("complete")),
        JSONMember("content", value: .array([.object(try JSONObject(members: [JSONMember("type", value: .string("text")), JSONMember("text", value: .string(value))]))]))]))
}

private func makeServer() async throws -> Server {
    // The server validates every Mcp-Param-* header against the body (HeaderMismatch otherwise).
    let regional = ToolRegistration(definition: try json(#"""
        {"name":"regional","inputSchema":{"type":"object","properties":{
          "region":{"type":"string","x-mcp-header":"Region"},"priority":{"type":"integer","x-mcp-header":"Priority"},"note":{"type":"string"}}}}
        """#)) { input, _ in
        guard case .value(let arguments) = input else { return try text("") }
        return try text(arguments.objectValue?["region"]?.stringValue ?? "")
    }
    let slow = ToolRegistration(definition: try json(#"{"name":"slow","inputSchema":{"type":"object"}}"#)) { _, context in
        // JSON responses have no event channel; progress is best effort.
        _ = try? await context.progress(JSONNumber(integer: 1), total: JSONNumber(integer: 2), message: "half")
        return try text("done")
    }
    let name = InputDescriptor(identifier: ScalarText("name"), request: try json(#"""
        {"method":"elicitation/create","params":{"mode":"form","message":"Your name?","requestedSchema":{"type":"object","properties":{"name":{"type":"string"}}}}}
        """#))
    let greet = ToolRegistration(definition: try json(#"{"name":"greet","inputSchema":{"type":"object"}}"#),
        rounds: MultiRoundProvider(version: ScalarText("v1"), inputs: [name], replay: .integrityOnly) { _, round, _ in
            guard let reply = round.responses["name"] else { return .inputRequired(.init(inputs: [name.identifier], state: .null)) }
            return .complete(try text("Hello, \(reply.objectValue?["content"]?.objectValue?["name"]?.stringValue ?? "?")!"))
        })
    return try await Server.make(info: json(#"{"name":"http-client-tests","version":"1"}"#),
        catalog: ServerCatalog(tools: [regional, slow, greet], listChanged: [.listTools]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("c"), material: Data(repeating: 4, count: 32))], active: ScalarText("c"), clock: { 1000 }),
        continuations: RequestStateProtector(keys: [.init(identifier: ScalarText("s"), material: Data(repeating: 6, count: 32))], active: ScalarText("s"),
            namespace: ScalarText("http-client-tests"), epoch: ScalarText("v1"), clock: { 1000 }))
}

/// Runs an HTTP server on loopback for the body's duration.
private func withHTTP(_ server: Server, mode: HTTPTransport.ResponseMode, _ body: @escaping @Sendable (URL) async throws -> Void) async throws {
    let transport = try HTTPTransport(server: server, configuration: .init(
        authority: AuthorityPolicy(authorities: ["localhost"], origins: [], portPolicy: .boundListener),
        security: .loopbackDevelopment(anonymous), responseMode: mode))
    let ready = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy: .bufferingNewest(1))
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { defer { ready.continuation.finish() }; do { try await transport.run { ready.continuation.yield($0) } } catch is CancellationError {} }
        var iterator = ready.stream.makeAsyncIterator()
        let address = try #require(await iterator.next())
        do { try await body(try #require(URL(string: "http://localhost:\(address.port)/mcp"))) }
        catch { await transport.shutdown(); throw error }
        await transport.shutdown()
        try await group.waitForAll()
    }
}

@Suite(.serialized) struct HTTPClientTransportCases {
    @Test(arguments: [HTTPTransport.ResponseMode.json, .sse])
    func clientAndServerInteroperateOverHTTP(_ mode: HTTPTransport.ResponseMode) async throws {
        let server = try await makeServer()
        try await withHTTP(server, mode: mode) { endpoint in
            let client = Client(transport: HTTPClientTransport(endpoint: endpoint), configuration: .init(
                info: try json(#"{"name":"swift-client","version":"0.1"}"#),
                elicitation: .init { _ in try json(#"{"action":"accept","content":{"name":"Ada"}}"#) }))
            #expect(try await client.discover().supportedVersions.contains("2026-07-28"))
            #expect(try await client.listTools().items.map(\.name).sorted() == ["greet", "regional", "slow"])
            // Mcp-Name and Mcp-Param-* are checked by the server against the body; non-ASCII is base64.
            #expect(try await client.callTool("regional", arguments: try json(#"{"region":"Zürich","priority":7,"note":"x"}"#)).text == "Zürich")
            #expect(try await client.callTool("greet").text == "Hello, Ada!")
            let seen = Mutex(0)
            #expect(try await client.callTool("slow", onProgress: { _ in seen.withLock { $0 += 1 } }).text == "done")
            // Progress needs a stream; a JSON-only server answers without it.
            #expect(seen.withLock { $0 } == (mode == .sse ? 1 : 0))
        }
    }

    @Test func listenStreamsOverServerSentEvents() async throws {
        let server = try await makeServer()
        try await withHTTP(server, mode: .sse) { endpoint in
            let client = Client(transport: HTTPClientTransport(endpoint: endpoint))
            let events = Mutex<[String]>([])
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await client.listen(try json(#"{"toolsListChanged":true}"#)) { event in
                        switch event {
                        case .acknowledged: events.withLock { $0.append("ack") }
                        case .toolsChanged: events.withLock { $0.append("tools") }
                        default: break
                        }
                    }
                }
                let end = ContinuousClock.now.advanced(by: .seconds(10))
                while !events.withLock({ $0.contains("ack") }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
                try await server.publish(.toolsChanged, audience: .principal(anonymous))
                while !events.withLock({ $0.contains("tools") }), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
                group.cancelAll()
                _ = try? await group.waitForAll()
            }
            #expect(events.withLock { $0 } == ["ack", "tools"])
        }
    }

    @Test func serverSentEventsParseSplitLinesCommentsAndMultilineData() throws {
        var parser = ServerSentEvents(maximumBytes: 64)
        var events = try parser.feed(Array(": keep-alive\r\n\r\nevent: message\r\ndata: {\"a\"".utf8))
        events += try parser.feed(Array(":1}\r\n\r\ndata: x\ndata: y\n\n".utf8))
        events += try parser.finish()
        #expect(events.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, "x\ny"])
        var small = ServerSentEvents(maximumBytes: 4)
        #expect(throws: HTTPClientTransportError.messageTooLarge) { _ = try small.feed(Array("data: 12345\n\n".utf8)) }
    }
}
