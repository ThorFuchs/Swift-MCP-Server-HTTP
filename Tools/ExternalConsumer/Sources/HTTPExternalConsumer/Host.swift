// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import JSON
import MCPClientAuthorization
import MCPHTTPAuthorization
import MCPProtocol
import MCPServer
import Synchronization

enum SmokeFailure: Error { case check(String) }

func require(_ condition: Bool, _ label: String) throws {
    guard condition else { throw SmokeFailure.check(label) }
}

func passed(_ label: String) { print("H5_CONSUMER case=\(label) PASS") }

func json(_ text: String) throws -> JSON {
    try WireCodec.parse(Array(text.utf8), limits: .balanced).result
}

final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

struct Verifier: TokenVerifier {
    let token: String
    let issuer: String

    func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
        try Task.checkCancellation()
        guard bearerToken == token || bearerToken == "consumer-scope-denied" else {
            throw AuthorizationMiddleware.Failure.invalidToken
        }
        let scopes: Set<ScalarText> = bearerToken == token ? [ScalarText("read")] : []
        return .init(principal: .init(subject: ScalarText("external-consumer"), issuer: ScalarText(issuer),
            resource: resource, scopes: scopes), expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 300)
    }
}

struct Browser: AuthorizationUserAgent {
    let client: HTTPClient
    let issuer: String
    let calls: Counter

    func authorize(_ request: AuthorizationRequest) async throws -> URL {
        try require(request.issuer == issuer, "browser issuer")
        var target = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
        target?.query = nil
        try require(target?.string == issuer + "/authorize", "browser destination")
        let response = try await client.execute(HTTPClientRequest(url: request.url.absoluteString), timeout: .seconds(5))
        _ = try await response.body.collect(upTo: 4096)
        guard response.status.code == 302, let location = response.headers.first(name: "Location"),
              let redirect = URL(string: location) else { throw SmokeFailure.check("browser redirect") }
        calls.increment()
        // Host capture only: never follow the synthetic callback URL.
        return redirect
    }
}

struct NoBrowser: AuthorizationUserAgent {
    func authorize(_ request: AuthorizationRequest) async throws -> URL {
        throw SmokeFailure.check("unexpected authorization after restore")
    }
}

func makeServer(resource: String, streaming: Bool, effects: Counter) async throws -> Server {
    let echo = ToolRegistration(definition: try json(#"{"name":"echo","inputSchema":{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}},"required":["region"]}}"#)) { input, context in
        try require(context.principal.subject == ScalarText("external-consumer"), "provider identity")
        try require(context.principal.resource == ScalarText(resource), "provider resource")
        guard case .value(let args) = input, let value = args.objectValue?["region"]?.stringValue else {
            throw SmokeFailure.check("tool input")
        }
        effects.increment()
        if streaming { try await context.progress(JSONNumber(integer: 1), total: JSONNumber(integer: 2)) }
        return .object(try JSONObject(members: [
            .init("resultType", value: .string("complete")),
            .init("content", value: .array([.object(try JSONObject(members: [
                .init("type", value: .string("text")), .init("text", value: .string(value))
            ]))]))
        ]))
    }
    let resourceProvider = ResourceProvider(definition: try json(#"{"name":"greeting","uri":"demo://greeting"}"#)) { _, _ in
        try json(#"{"resultType":"complete","contents":[{"uri":"demo://greeting","text":"Hello"}]}"#)
    }
    let promptProvider = PromptProvider(definition: try json(#"{"name":"greet"}"#)) { _, _ in
        try json(#"{"resultType":"complete","messages":[{"role":"user","content":{"type":"text","text":"Hello"}}]}"#)
    }
    return try await Server.make(info: json(#"{"name":"external-consumer","version":"1"}"#),
        catalog: ServerCatalog(tools: [echo], resources: [resourceProvider], prompts: [promptProvider]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("synthetic"), material: Data(repeating: 7, count: 32))],
            active: ScalarText("synthetic"), clock: { 1000 }))
}
