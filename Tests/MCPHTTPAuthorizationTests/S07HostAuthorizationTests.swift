// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPHTTPAuthorization

private let s07Resource = ScalarText("https://example.com/mcp")
private let s07Issuer = ScalarText("https://issuer.example")
private let s07Credential = "s07-synthetic-credential"
private func s07Principal(_ scopes: Set<ScalarText>) -> VerifiedPrincipal {
    .init(subject: ScalarText("verified-user"), issuer: s07Issuer, resource: s07Resource, scopes: scopes)
}
// Trusted-result fixture, NOT token cryptography. A production host first checks
// signature/introspection, issuer, audience, expiry and token constraints. Only
// then may it apply its explicit, finite implication table to verified claims.
private actor S07HierarchyVerifier: TokenVerifier {
    let claims: Set<ScalarText>, expand: Bool, expiry: Int64
    private(set) var calls = 0
    init(claims: Set<ScalarText>, expand: Bool = true, expiry: Int64 = 200) {
        self.claims = claims; self.expand = expand; self.expiry = expiry
    }
    func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
        #expect(bearerToken == s07Credential && resource == s07Resource)
        calls += 1
        var effective = claims
        if expand && claims.contains(ScalarText("documents:manage")) {
            effective.formUnion([ScalarText("documents:read"), ScalarText("documents:write")])
        }
        return .init(principal: s07Principal(effective), expiresAtUnixSeconds: expiry)
    }
}
private func s07Middleware(_ verifier: S07HierarchyVerifier, policy: ScopePolicy,
    now: @escaping @Sendable () -> Int64 = { 100 }) throws -> AuthorizationMiddleware {
    try .init(verifier: verifier, resource: s07Resource, issuers: [s07Issuer], policy: policy, now: now)
}
private func s07Credentials() throws -> HeaderFields {
    try HeaderFields([.init("Authorization", "Bearer " + s07Credential)])
}
private func s07ScopePolicy() -> ScopePolicy {
    .init(baseline: [ScalarText("mcp:use")], methods: [.callTool: [ScalarText("tools:call")]],
        targets: [.init(method: .callTool, name: ScalarText("edit")): [ScalarText("documents:write")]])
}

@Suite(.serialized) struct S07HostAuthorization {
    @Test func hostScopeImplicationsAreExplicitAndDoNotGrantWildcards() async throws {
        let policy = s07ScopePolicy()
        #expect(policy.required(method: .callTool, name: ScalarText("edit")) ==
            [ScalarText("mcp:use"), ScalarText("tools:call"), ScalarText("documents:write")])
        let claims: Set<ScalarText> = [ScalarText("mcp:use"), ScalarText("tools:call"), ScalarText("documents:manage")]
        let verifier = S07HierarchyVerifier(claims: claims)
        let auth = try s07Middleware(verifier, policy: policy)
        let expanded = try await auth.authorize(headers: s07Credentials(), method: .callTool, name: ScalarText("edit"))
        #expect(expanded.scopes == claims.union([ScalarText("documents:read"), ScalarText("documents:write")]))
        #expect(!expanded.scopes.contains(ScalarText("billing:read")))
        // ScopePolicy itself uses exact containment. Syntax is never an implicit
        // implication rule; the embedding host supplies its actual hierarchy.
        #expect(!policy.allows(s07Principal(claims), method: .callTool, name: ScalarText("edit")))
        let wildcard = S07HierarchyVerifier(claims: [ScalarText("mcp:use"), ScalarText("tools:call"), ScalarText("documents:*")])
        let wildcardAuth = try s07Middleware(wildcard, policy: policy)
        await #expect(throws: AuthorizationMiddleware.Failure.insufficientScope) {
            _ = try await wildcardAuth.authorize(headers: s07Credentials(), method: .callTool, name: ScalarText("edit"))
        }
        let reader = S07HierarchyVerifier(claims: [ScalarText("mcp:use"), ScalarText("tools:call"), ScalarText("documents:read")])
        let readAuth = try s07Middleware(reader, policy: policy)
        await #expect(throws: AuthorizationMiddleware.Failure.insufficientScope) {
            _ = try await readAuth.authorize(headers: s07Credentials(), method: .callTool, name: ScalarText("edit"))
        }
        let editorCalls = await verifier.calls, readerCalls = await reader.calls, wildcardCalls = await wildcard.calls
        #expect(editorCalls == 1 && readerCalls == 1 && wildcardCalls == 1)
    }

    @Test func challengesIncludeTheCompleteScopeUnionAndSupplementalBaseline() async throws {
        let verifier = S07HierarchyVerifier(claims: [])
        let middleware = try s07Middleware(verifier, policy: s07ScopePolicy())
        let metadata = try await ProtectedResourceMetadata(resource: s07Resource, authorizationServers: [s07Issuer.description])
        let policy = try HTTPAuthorizationPolicy(middleware: middleware, metadata: metadata)
        do {
            try policy.authorize(s07Principal([]), method: .callTool, name: ScalarText("edit"))
            Issue.record("Expected complete method/target denial")
        } catch let failure as HTTPAccessFailure {
            #expect(failure.response.status == 403 && failure.response.body.isEmpty)
            let challenge = try #require(failure.response.fields.first { $0.name.lowercased() == "www-authenticate" }?.value)
            #expect(challenge == "Bearer resource_metadata=\"https://example.com/.well-known/oauth-protected-resource/mcp\", error=\"insufficient_scope\", scope=\"documents:write mcp:use tools:call\"")
            #expect(!challenge.contains(s07Credential))
        }
        let baseline = s07Principal([ScalarText("mcp:use")])
        try policy.authorizeSupplemental(baseline, method: ScalarText("com.example/status"))
        do {
            try policy.authorizeSupplemental(s07Principal([]), method: ScalarText("com.example/status"))
            Issue.record("Supplemental route must require the host baseline")
        } catch let failure as HTTPAccessFailure {
            #expect(failure.response.status == 403)
            #expect(failure.response.fields.first?.value.contains("scope=\"mcp:use\"") == true)
        }
        do {
            try policy.authorize(baseline, requiredScopes: [ScalarText("documents:read")])
            Issue.record("Catalog scopes must still be authorized")
        } catch let failure as HTTPAccessFailure { #expect(failure.response.status == 403) }
        #expect(await verifier.calls == 0)
    }

    @Test func verifiedPrincipalAloneReachesCoreDespiteClientIdentityClaims() async throws {
        let verifier = S07HierarchyVerifier(claims: [ScalarText("documents:manage")])
        let auth = try s07Middleware(verifier, policy: ScopePolicy(baseline: []))
        let verified = try await auth.authenticate(headers: s07Credentials())
        let calls = Mutex(0)
        let definition = try WireCodec.parse(Array(#"{"name":"read","inputSchema":{"type":"object"}}"#.utf8), limits: .balanced).result
        let tool = ToolRegistration(definition: definition, requiredScopes: [ScalarText("documents:read")]) { _, context in
            calls.withLock { $0 += 1 }
            #expect(context.principal == verified)
            #expect(context.principal.subject == ScalarText("verified-user"))
            #expect(context.principal.scopes.contains(ScalarText("documents:write")))
            return try WireCodec.parse(Array(#"{"resultType":"complete","content":[]}"#.utf8), limits: .balanced).result
        }
        let info = try WireCodec.parse(Array(#"{"name":"s07-host","version":"1"}"#.utf8), limits: .balanced).result
        let cursor = try CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 3, count: 32))], active: ScalarText("test"), clock: { 1000 })
        let server = try await Server.make(info: info, catalog: ServerCatalog(tools: [tool]), cursors: cursor)
        let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{},"io.modelcontextprotocol/clientInfo":{"name":"administrator","version":"1"},"com.example/claimedSubject":"administrator"}}}"#.utf8)
        let response = try #require(await server.handle(request, principal: verified, origin: ScalarText("s07-origin")))
        #expect(try WireCodec.parse(Array(response), limits: .balanced).result.objectValue?["result"] != nil)
        #expect(!String(decoding: response, as: UTF8.self).contains(s07Credential))
        #expect(calls.withLock { $0 } == 1)
        await #expect(throws: CoreFailure.insufficientScopes) {
            _ = try await server.handle(request, principal: s07Principal([]), origin: ScalarText("s07-origin"))
        }
        let verifierCalls = await verifier.calls
        #expect(calls.withLock { $0 } == 1 && verifierCalls == 1)
        let activity = await server.activity
        #expect(activity.active == 0 && activity.requests == 0 && activity.leases == 0 && activity.bufferedBytes == 0)
    }

    @Test func tokenExpiryIsRecheckedOnEachRequestWithoutPositiveResultCache() async throws {
        let clock = Mutex(Int64(100))
        let verifier = S07HierarchyVerifier(claims: [], expiry: 101)
        let auth = try s07Middleware(verifier, policy: ScopePolicy(baseline: []), now: { clock.withLock { $0 } })
        #expect(try await auth.authenticate(headers: s07Credentials()).subject == ScalarText("verified-user"))
        clock.withLock { $0 = 101 }
        await #expect(throws: AuthorizationMiddleware.Failure.invalidToken) {
            _ = try await auth.authenticate(headers: s07Credentials())
        }
        #expect(await verifier.calls == 2)
    }

    @Test func metadataRouteDocumentAndChallengeUseOneExactResourceIdentity() async throws {
        let resource = ScalarText("https://example.com/api/mcp")
        let verifier = S07HierarchyVerifier(claims: [])
        let metadata = try await ProtectedResourceMetadata(resource: resource, authorizationServers: [s07Issuer.description],
            scopes: ["documents:write", "documents:read", "documents:read"])
        let mismatched = try s07Middleware(verifier, policy: ScopePolicy(baseline: []))
        #expect(throws: AuthorizationMiddleware.Failure.invalidConfiguration) {
            _ = try HTTPAuthorizationPolicy(middleware: mismatched, metadata: metadata)
        }
        let matching = try AuthorizationMiddleware(verifier: verifier, resource: resource, issuers: [s07Issuer],
            policy: ScopePolicy(baseline: []), now: { 100 })
        let policy = try HTTPAuthorizationPolicy(middleware: matching, metadata: metadata)
        #expect(metadata.path == "/.well-known/oauth-protected-resource/api/mcp")
        let response = try #require(policy.metadata(path: metadata.path))
        #expect(response.status == 200)
        let body = try WireCodec.parse(Array(response.body), limits: .conservative).result
        #expect(body.objectValue?["resource"]?.stringValue == resource.description)
        #expect(body.objectValue?["authorization_servers"]?.arrayValue?.compactMap { $0.stringValue } == [s07Issuer.description])
        #expect(body.objectValue?["scopes_supported"]?.arrayValue?.compactMap { $0.stringValue } == ["documents:read", "documents:write"])
        #expect(body.objectValue?["bearer_methods_supported"]?.arrayValue?.compactMap { $0.stringValue } == ["header"])
        for path in ["/mcp", metadata.path + "/", metadata.path + "?token=private", "/.well-known/oauth-protected-resource"] {
            #expect(policy.metadata(path: path) == nil)
        }
        do {
            _ = try await policy.authenticate(headers: HeaderFields([]))
            Issue.record("Missing credentials must challenge")
        } catch let failure as HTTPAccessFailure {
            #expect(failure.response.status == 401 && failure.response.body.isEmpty)
            #expect(failure.response.fields.first?.value == "Bearer resource_metadata=\"https://example.com/.well-known/oauth-protected-resource/api/mcp\"")
        }
        #expect(await verifier.calls == 0)
    }
}
