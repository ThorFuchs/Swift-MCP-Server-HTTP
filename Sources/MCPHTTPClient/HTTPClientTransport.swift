// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import MCPClient
import NIOCore
import NIOHTTP1

public enum HTTPClientTransportError: Error, Sendable, Equatable {
    /// A non-success status without a JSON-RPC body.
    case status(Int)
    /// A response that is neither `application/json` nor `text/event-stream`.
    case contentType(String)
    /// A message or SSE event larger than `HTTPClientTransport.maximumMessageBytes`.
    case messageTooLarge
}

/// Streamable HTTP for MCP 2026-07-28: one POST per request with `MCP-Protocol-Version`,
/// `Mcp-Method`, `Mcp-Name` and mirrored `Mcp-Param-*` headers; the response is a single
/// JSON message or an SSE stream of notifications ending with the response. Closing the
/// stream (cancelling the calling task) is the cancellation signal.
public struct HTTPClientTransport: ClientTransport {
    public let endpoint: URL
    public let maximumMessageBytes: Int
    public let timeout: TimeAmount
    private let client: HTTPClient
    private let headers: @Sendable () async throws -> [(name: String, value: String)]

    /// - Parameters:
    ///   - client: the AsyncHTTPClient to use; the caller owns its lifetime (`.shared` by default).
    ///   - headers: extra headers per request, for example `Authorization` from a token store.
    ///   - timeout: deadline of one exchange, including listen streams.
    public init(endpoint: URL, client: HTTPClient = .shared, maximumMessageBytes: Int = 16 * 1024 * 1024,
                timeout: TimeAmount = .hours(1), headers: @escaping @Sendable () async throws -> [(name: String, value: String)] = { [] }) {
        self.endpoint = endpoint; self.client = client; self.maximumMessageBytes = maximumMessageBytes
        self.timeout = timeout; self.headers = headers
    }

    public var mirrorsToolParameters: Bool { true }

    public func exchange(_ request: OutgoingRequest, receive: @escaping @Sendable (Data) async throws -> Void) async throws {
        var http = HTTPClientRequest(url: endpoint.absoluteString)
        http.method = .POST
        http.headers.add(name: "Content-Type", value: "application/json")
        http.headers.add(name: "Accept", value: "application/json, text/event-stream")
        http.headers.add(name: "MCP-Protocol-Version", value: Client.protocolVersion)
        http.headers.add(name: "Mcp-Method", value: request.method)
        if let name = request.name { http.headers.add(name: "Mcp-Name", value: HeaderValue.encode(name)) }
        for header in request.parameterHeaders { http.headers.add(name: header.name, value: header.value) }
        for header in try await headers() { http.headers.add(name: header.name, value: header.value) }
        http.body = .bytes(ByteBuffer(bytes: request.body))

        let response = try await client.execute(http, timeout: timeout)
        let type = response.headers.first(name: "Content-Type")?.lowercased() ?? ""
        if type.hasPrefix("text/event-stream") {
            var parser = ServerSentEvents(maximumBytes: maximumMessageBytes)
            for try await chunk in response.body {
                for event in try parser.feed(Array(buffer: chunk)) { try await receive(event) }
            }
            for event in try parser.finish() { try await receive(event) }
            return
        }
        if type.hasPrefix("application/json") {
            // JSON-RPC errors arrive with 4xx statuses (for example HeaderMismatch); deliver them.
            let body = try await response.body.collect(upTo: maximumMessageBytes)
            try await receive(Data(buffer: body))
            return
        }
        guard (200..<300).contains(Int(response.status.code)) else { throw HTTPClientTransportError.status(Int(response.status.code)) }
        throw HTTPClientTransportError.contentType(type)
    }
}

/// Incremental `text/event-stream` parser: each event's `data` lines joined by `\n`.
/// Comments (`:`), `event`, `id` and `retry` fields are ignored; events are bounded.
struct ServerSentEvents {
    let maximumBytes: Int
    private var line: [UInt8] = []
    private var data: [UInt8] = []
    private var hasData = false
    private var lastWasCR = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    mutating func feed(_ bytes: [UInt8]) throws -> [Data] {
        var events: [Data] = []
        for byte in bytes {
            if byte == 0x0A, lastWasCR { lastWasCR = false; continue }
            lastWasCR = byte == 0x0D
            if byte == 0x0A || byte == 0x0D {
                if let event = try endLine() { events.append(event) }
            } else {
                line.append(byte)
                guard line.count <= maximumBytes else { throw HTTPClientTransportError.messageTooLarge }
            }
        }
        return events
    }

    mutating func finish() throws -> [Data] {
        var events: [Data] = []
        if !line.isEmpty, let event = try endLine() { events.append(event) }
        if hasData { events.append(Data(data)); data = []; hasData = false }
        return events
    }

    private mutating func endLine() throws -> Data? {
        defer { line = [] }
        if line.isEmpty {
            guard hasData else { return nil }
            let event = Data(data); data = []; hasData = false
            return event
        }
        if line.first == UInt8(ascii: ":") { return nil }
        let colon = line.firstIndex(of: UInt8(ascii: ":")) ?? line.endIndex
        guard line[..<colon].elementsEqual("data".utf8) else { return nil }
        var value = line[min(colon + 1, line.endIndex)...]
        if value.first == UInt8(ascii: " ") { value = value.dropFirst() }
        if hasData { data.append(0x0A) }
        data.append(contentsOf: value); hasData = true
        guard data.count <= maximumBytes else { throw HTTPClientTransportError.messageTooLarge }
        return nil
    }
}
