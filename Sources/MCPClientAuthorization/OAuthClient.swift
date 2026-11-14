// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import MCPHTTPClient

/// OAuth 2.1 authorization for one MCP endpoint (ADR-0006, slices A1–A3).
///
/// Give it to `HTTPClientTransport(endpoint:authorization:)`. On `401` it discovers the
/// protected resource and authorization server metadata, identifies the client (pre-registered,
/// client ID metadata document or dynamic registration), runs the authorization code flow with
/// PKCE `S256`, `state`, `resource` and `iss` checks through the host's user agent, and sends the
/// token as `Authorization: Bearer`. Concurrent challenges share one flow.
///
/// Not yet: `403 insufficient_scope` step-up, refresh tokens and a host token store (A4–A5).
public actor OAuthClient: HTTPClientAuthorizing {
    public let endpoint: URL
    public nonisolated let configuration: OAuthClientConfiguration
    private let userAgent: any AuthorizationUserAgent
    private let http: any AuthorizationHTTP

    private var token: AccessToken?
    private var clients: [String: ResolvedClient] = [:]
    private var authorizing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - endpoint: the MCP endpoint, the same URL the transport uses.
    ///   - client: used for metadata, registration and token requests; the caller owns it.
    public init(endpoint: URL, configuration: OAuthClientConfiguration, userAgent: any AuthorizationUserAgent, client: HTTPClient = .shared) {
        self.init(endpoint: endpoint, configuration: configuration, userAgent: userAgent,
                  http: AsyncHTTPClientExchange(client: client, timeout: configuration.timeout))
    }

    init(endpoint: URL, configuration: OAuthClientConfiguration, userAgent: any AuthorizationUserAgent, http: any AuthorizationHTTP) {
        self.endpoint = endpoint; self.configuration = configuration; self.userAgent = userAgent; self.http = http
    }

    /// Whether the client currently holds an access token.
    public var isAuthorized: Bool { token != nil }

    /// Forgets the access token; the next challenge starts a new authorization.
    public func signOut() { token = nil }

    public func authorizationHeaders(for endpoint: URL) async throws -> [(name: String, value: String)] {
        guard endpoint == self.endpoint, let token else { return [] }
        return [("Authorization", "Bearer " + token.value)]
    }

    public func handleChallenge(_ challenge: HTTPAuthorizationChallenge) async throws -> Bool {
        // 403 insufficient_scope (step-up) is slice A4.
        guard challenge.endpoint == endpoint, challenge.status == 401 else { return false }
        if hasNewerToken(than: challenge) { return true }
        if authorizing {
            await withCheckedContinuation { waiters.append($0) }
            return hasNewerToken(than: challenge)
        }
        authorizing = true
        defer {
            authorizing = false
            let resumed = waiters; waiters = []
            for waiter in resumed { waiter.resume() }
        }
        token = nil
        token = try await authorize(hint: BearerChallenge.parameters(challenge.wwwAuthenticate) ?? [:])
        return true
    }

    /// A token other than the one the rejected request carried.
    private func hasNewerToken(than challenge: HTTPAuthorizationChallenge) -> Bool {
        guard let token else { return false }
        return challenge.sentAuthorization != "Bearer " + token.value
    }

    private func authorize(hint parameters: [String: String]) async throws -> AccessToken {
        let discovery = Discovery(http: http, insecureLoopback: configuration.allowsInsecureLoopback, maximumBytes: configuration.maximumDocumentBytes)
        guard URLRules.isAllowed(endpoint, insecureLoopback: configuration.allowsInsecureLoopback) else {
            throw OAuthClientError.insecureURL(endpoint.absoluteString)
        }
        let resource = try await discovery.protectedResource(for: endpoint, hint: parameters["resource_metadata"])
        let server = try await discovery.authorizationServer(resource.authorizationServers[0])
        let flow = AuthorizationFlow(http: http, configuration: configuration)
        let client: ResolvedClient
        if let known = clients[server.issuer] { client = known }
        else { client = try await flow.client(for: server); clients[server.issuer] = client }
        // Scope: the challenge's, else every scope the resource lists, else none.
        let scope = parameters["scope"] ?? resource.scopesSupported?.joined(separator: " ")
        try Task.checkCancellation()
        return try await flow.authorize(server: server, client: client, resource: resource.resource, scope: scope, userAgent: userAgent)
    }
}
