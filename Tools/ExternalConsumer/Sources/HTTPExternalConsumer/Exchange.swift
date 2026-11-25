// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import JSON
import MCPClient
import MCPClientAuthorization
import MCPHTTPClient
import MCPProtocol
import NIOSSL

private func denied(_ client: Client, status: Int) async throws {
    do {
        _ = try await client.callTool("echo", arguments: json(#"{"region":"test"}"#))
        throw SmokeFailure.check("unexpected protected tool success")
    } catch let error as HTTPClientTransportError {
        try require(error == .status(status), "rejection status")
    }
}

func exercise(endpoint: URL, issuer: String, token: String, ca: String,
              resource: String, streaming: Bool, effects: Counter) async throws {
    var tls = TLSConfiguration.makeClientConfiguration()
    tls.certificateVerification = .fullVerification
    tls.trustRoots = .file(ca)
    let http = HTTPClient(eventLoopGroupProvider: .singleton,
        configuration: .init(tlsConfiguration: tls, redirectConfiguration: .disallow))
    do {
        let metadataURL = resource.replacingOccurrences(of: "/mcp", with: "/.well-known/oauth-protected-resource/mcp")
        let metadata = try await http.execute(HTTPClientRequest(url: metadataURL), timeout: .seconds(5))
        try require(metadata.status.code == 200, "metadata status")
        let body = try await metadata.body.collect(upTo: 65536)
        let document = try WireCodec.parse(Array(body.readableBytesView), limits: .balanced).result
        try require(document.objectValue?["resource"]?.stringValue == resource, "metadata resource")
        try require(document.objectValue?["authorization_servers"]?.arrayValue?.first?.stringValue == issuer, "metadata issuer")
        passed("tls_metadata")

        let bare = Client(transport: HTTPClientTransport(endpoint: endpoint, client: http, timeout: .seconds(5),
            headers: { [("Mcp-Param-Region", "test")] }))
        try await denied(bare, status: 401)
        let invalid = Client(transport: HTTPClientTransport(endpoint: endpoint, client: http, timeout: .seconds(5),
            headers: { [("Authorization", "Bearer consumer-invalid"), ("Mcp-Param-Region", "test")] }))
        try await denied(invalid, status: 401)
        let scoped = Client(transport: HTTPClientTransport(endpoint: endpoint, client: http, timeout: .seconds(5),
            headers: { [("Authorization", "Bearer consumer-scope-denied"), ("Mcp-Param-Region", "test")] }))
        try await denied(scoped, status: 403)
        try require(effects.count == 0, "denials have no provider effects")
        passed("denials")

        let store = InMemoryTokenStore()
        let calls = Counter()
        let config = OAuthClientConfiguration(
            identity: ClientIdentity(preRegistered: [PreRegisteredClient(issuer: issuer, clientID: "external-consumer", authentication: TokenEndpointAuthentication.none)]),
            redirectURI: URL(string: "http://127.0.0.1:9/callback")!,
            timeout: .seconds(5), requestsOfflineAccess: false)
        let oauth = OAuthClient(endpoint: endpoint, configuration: config,
            userAgent: Browser(client: http, issuer: issuer, calls: calls), tokenStore: store, client: http)
        let client = Client(transport: HTTPClientTransport(endpoint: endpoint, client: http, timeout: .seconds(5), authorization: oauth))
        let description = try await client.discover()
        try require(description.supportedVersions.contains("2026-07-28"), "discovery")
        let saved = await store.load(endpoint: endpoint)
        let authorized = await oauth.isAuthorized
        try require(authorized && saved?.issuer == issuer && saved?.resource == resource
            && saved?.clientID == "external-consumer" && saved?.accessToken == token && calls.count == 1, "OAuth grant/persistence")
        passed("oauth_login")

        let tools = try await client.listTools()
        try require(tools.items.map(\.name) == ["echo"], "tools list")
        let progress = Counter()
        let result = try await client.callTool("echo", arguments: json(#"{"region":"Zürich"}"#), onProgress: { _ in progress.increment() })
        try require(result.text == "Zürich" && effects.count == 1, "tool result and verified principal")
        try require(progress.count == (streaming ? 1 : 0), "mode-specific progress")
        passed("tools_mirrors_progress")

        let resources = try await client.listResources()
        try require(resources.items.map(\.uri) == ["demo://greeting"], "resources list")
        let contents = try await client.readResource("demo://greeting")
        try require(contents.count == 1 && contents[0].objectValue?["text"]?.stringValue == "Hello", "resource read")
        passed("resources")

        let prompts = try await client.listPrompts()
        try require(prompts.items.map(\.name) == ["greet"], "prompts list")
        let prompt = try await client.getPrompt("greet")
        try require(prompt.objectValue?["messages"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.stringValue == "Hello", "prompt get")
        passed("prompts")

        let restored = OAuthClient(endpoint: endpoint, configuration: config, userAgent: NoBrowser(), tokenStore: store, client: http)
        let restoredClient = Client(transport: HTTPClientTransport(endpoint: endpoint, client: http, timeout: .seconds(5), authorization: restored))
        let restoredTools = try await restoredClient.listTools()
        let restoredAuthorized = await restored.isAuthorized
        try require(restoredTools.items.map(\.name) == ["echo"] && restoredAuthorized, "restore")
        try await restored.signOut()
        let remaining = await store.load(endpoint: endpoint)
        let headers = try await restored.authorizationHeaders(for: endpoint)
        let signedOut = !(await restored.isAuthorized)
        try require(remaining == nil && headers.isEmpty && signedOut, "sign out")
        try require(calls.count == 1 && effects.count == 1, "no additional grant or provider effects")
        passed("restore_signout")
        try await http.shutdown()
    } catch {
        try? await http.shutdown()
        throw error
    }
}
