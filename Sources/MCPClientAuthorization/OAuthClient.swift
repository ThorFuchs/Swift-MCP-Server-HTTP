// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import MCPHTTPClient

/// OAuth 2.1 authorization for one MCP endpoint (ADR-0006, slices A1–A5).
///
/// Give it to `HTTPClientTransport(endpoint:authorization:)`. On `401` it reads the protected
/// resource metadata again: while the authorization server is unchanged it refreshes the token
/// when it can; otherwise, and after a change of authorization server, it identifies the client
/// with that server (pre-registered, client ID metadata document or dynamic registration; never
/// reusing another server's credentials), runs the authorization code flow with PKCE `S256`,
/// `state`, `resource` and `iss` checks through the host's user agent, and sends the token as
/// `Authorization: Bearer`. On `403 insufficient_scope` it re-authorizes with the union of the
/// scopes it already asked for and the challenged ones, within `maximumStepUps`. With a
/// `TokenStore`, tokens and the client identity survive restarts. Concurrent challenges share
/// one flow.
public actor OAuthClient: HTTPClientAuthorizing {
    public let endpoint: URL
    public nonisolated let configuration: OAuthClientConfiguration
    private let userAgent: any AuthorizationUserAgent
    private let http: any AuthorizationHTTP
    private let tokenStore: (any TokenStore)?
    private let now: @Sendable () -> ContinuousClock.Instant

    /// The authorization server and client the current tokens belong to. The metadata is
    /// fetched lazily after a restore from the token store.
    private struct Session: Sendable {
        let issuer: String
        let resource: String
        let client: ResolvedClient
        var server: AuthorizationServerMetadata?
    }

    private var session: Session?
    private var token: AccessToken?
    private var expiry: ContinuousClock.Instant?
    /// The scopes the current token was requested with.
    private var requestedScopes: [String] = []
    private var stepUps = 0
    /// Client identities per issuer; never used with another issuer.
    private var clients: [String: ResolvedClient] = [:]
    private var restored = false
    private var authorizing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Refresh this long before the token expires.
    static let refreshMargin: Duration = .seconds(30)

    /// - Parameters:
    ///   - endpoint: the MCP endpoint, the same URL the transport uses.
    ///   - tokenStore: host persistence for tokens and the client identity; nil keeps them in memory.
    ///   - client: used for metadata, registration and token requests; the caller owns it.
    public init(endpoint: URL, configuration: OAuthClientConfiguration, userAgent: any AuthorizationUserAgent,
                tokenStore: (any TokenStore)? = nil, client: HTTPClient = .shared) {
        self.init(endpoint: endpoint, configuration: configuration, userAgent: userAgent, tokenStore: tokenStore,
                  http: AsyncHTTPClientExchange(client: client, timeout: configuration.timeout))
    }

    init(endpoint: URL, configuration: OAuthClientConfiguration, userAgent: any AuthorizationUserAgent, tokenStore: (any TokenStore)? = nil,
         http: any AuthorizationHTTP, now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.endpoint = endpoint; self.configuration = configuration; self.userAgent = userAgent
        self.tokenStore = tokenStore; self.http = http; self.now = now
    }

    /// Whether the client currently holds an access token.
    public var isAuthorized: Bool { token != nil }

    /// Forgets the tokens and deletes them from the token store; the next challenge starts a
    /// new authorization.
    public func signOut() async throws {
        token = nil; expiry = nil; requestedScopes = []; stepUps = 0; session = nil; restored = true
        try await tokenStore?.delete(endpoint: endpoint)
    }

    public func authorizationHeaders(for endpoint: URL) async throws -> [(name: String, value: String)] {
        guard endpoint == self.endpoint else { return [] }
        try await restoreIfNeeded()
        // A remote refresh rejection may retain the old token, but persistence
        // errors must reach the caller rather than silently desynchronizing storage.
        if let expiry, now() >= expiry - Self.refreshMargin, token?.refreshToken != nil, !authorizing {
            _ = try await exclusively { try await self.refreshed() }
        }
        guard let token else { return [] }
        return [("Authorization", "Bearer " + token.value)]
    }

    public func handleChallenge(_ challenge: HTTPAuthorizationChallenge) async throws -> Bool {
        guard challenge.endpoint == endpoint else { return false }
        try await restoreIfNeeded()
        let parameters = BearerChallenge.parameters(challenge.wwwAuthenticate) ?? [:]
        switch challenge.status {
        case 401:
            if hasNewerToken(than: challenge) { return true }
            if authorizing { await waitForAuthorization(); return hasNewerToken(than: challenge) }
            return try await exclusively {
                let resource = try await self.protectedResource(hint: parameters["resource_metadata"])
                if try await self.refreshedIfSameServer(resource) { return true }
                try await self.authorize(resource: resource, parameters: parameters, scopes: nil)
                return true
            }
        case 403:
            guard parameters["error"] == "insufficient_scope" else { return false }
            if hasNewerToken(than: challenge) { return true }
            if authorizing { await waitForAuthorization(); return hasNewerToken(than: challenge) }
            // A step-up only helps when the challenge asks for something not yet requested.
            let challenged = Self.scopes(parameters["scope"])
            guard !challenged.isEmpty, !Set(challenged).isSubset(of: Set(requestedScopes)), stepUps < configuration.maximumStepUps else { return false }
            return try await exclusively {
                await self.countStepUp()
                let resource = try await self.protectedResource(hint: parameters["resource_metadata"])
                try await self.authorize(resource: resource, parameters: parameters, scopes: await self.union(challenged))
                return true
            }
        default:
            return false
        }
    }

    // MARK: Single flight

    private func exclusively<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        authorizing = true
        defer {
            authorizing = false
            let resumed = waiters; waiters = []
            for waiter in resumed { waiter.resume() }
        }
        return try await body()
    }

    private func waitForAuthorization() async { await withCheckedContinuation { waiters.append($0) } }

    /// A token other than the one the rejected request carried.
    private func hasNewerToken(than challenge: HTTPAuthorizationChallenge) -> Bool {
        guard let token else { return false }
        return challenge.sentAuthorization != "Bearer " + token.value
    }

    private func countStepUp() { stepUps += 1 }

    private func union(_ challenged: [String]) -> [String] {
        var scopes = requestedScopes
        for scope in challenged where !scopes.contains(scope) { scopes.append(scope) }
        return scopes
    }

    static func scopes(_ text: String?) -> [String] {
        (text ?? "").split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    // MARK: Token store

    private func restoreIfNeeded() async throws {
        guard !restored else { return }
        // A failed load is retried with the next request.
        let loaded = try await tokenStore?.load(endpoint: endpoint)
        guard !restored else { return }
        restored = true
        guard let stored = loaded else { return }
        let client = ResolvedClient(clientID: stored.clientID, clientSecret: stored.clientSecret, authentication: stored.authentication)
        clients[stored.issuer] = client
        session = Session(issuer: stored.issuer, resource: stored.resource, client: client, server: nil)
        token = AccessToken(value: stored.accessToken, scope: nil, refreshToken: stored.refreshToken, expiresIn: nil)
        requestedScopes = stored.scopes
        expiry = stored.expiresAt.map { now() + .milliseconds(Int64(($0.timeIntervalSinceNow * 1000).rounded())) }
    }

    private func store(_ issued: AccessToken, scopes: [String]) async throws {
        // Commit the new credentials in memory only after persistence succeeds.
        // Otherwise an unsuccessful save could expose an unpersisted access token
        // and leave the restored client with a different token after restart.
        if let tokenStore, let session {
            try await tokenStore.save(StoredAuthorization(issuer: session.issuer, resource: session.resource, clientID: session.client.clientID,
                clientSecret: session.client.clientSecret, authentication: session.client.authentication, accessToken: issued.value,
                refreshToken: issued.refreshToken, scopes: scopes, expiresAt: issued.expiresIn.map { Date().addingTimeInterval(TimeInterval($0)) }),
                endpoint: endpoint)
        }
        token = issued
        requestedScopes = scopes
        expiry = issued.expiresIn.map { now() + .seconds($0) }
    }

    // MARK: Flows

    private var discovery: Discovery {
        Discovery(http: http, insecureLoopback: configuration.allowsInsecureLoopback, maximumBytes: configuration.maximumDocumentBytes)
    }

    private func protectedResource(hint: String?) async throws -> ProtectedResourceMetadata {
        guard URLRules.isAllowed(endpoint, insecureLoopback: configuration.allowsInsecureLoopback) else {
            throw OAuthClientError.insecureURL(endpoint.absoluteString)
        }
        return try await discovery.protectedResource(for: endpoint, hint: hint)
    }

    /// Refreshes only while the resource still names the authorization server the tokens came
    /// from (SEP-2352); a refresh token is never sent to another server.
    private func refreshedIfSameServer(_ resource: ProtectedResourceMetadata) async throws -> Bool {
        guard let session else { return false }
        guard session.issuer == resource.authorizationServers[0], session.resource == resource.resource else {
            // The endpoint moved: the old tokens and their store entry are void.
            token = nil; expiry = nil; self.session = nil
            try await tokenStore?.delete(endpoint: endpoint)
            return false
        }
        return try await refreshed()
    }

    /// Uses the refresh token, if any; true when a new access token was stored.
    private func refreshed() async throws -> Bool {
        guard let refreshToken = token?.refreshToken, var current = session else { return false }
        if current.server == nil {
            guard let server = try? await discovery.authorizationServer(current.issuer) else { return false }
            current.server = server
            session = current
        }
        guard let server = current.server else { return false }
        let flow = AuthorizationFlow(http: http, configuration: configuration)
        guard let refreshed = try? await flow.refresh(refreshToken, server: server, client: current.client, resource: current.resource) else {
            return false
        }
        try await store(refreshed, scopes: requestedScopes)
        return true
    }

    private func authorize(resource: ProtectedResourceMetadata, parameters: [String: String], scopes requested: [String]?) async throws {
        let server = try await discovery.authorizationServer(resource.authorizationServers[0])
        let flow = AuthorizationFlow(http: http, configuration: configuration)
        let client: ResolvedClient
        if let known = clients[server.issuer] { client = known }
        else { client = try await flow.client(for: server); clients[server.issuer] = client }
        session = Session(issuer: server.issuer, resource: resource.resource, client: client, server: server)

        // Scope: the given set (step-up), else the challenge's, else every scope the resource
        // lists, else none; plus offline_access when wanted and offered.
        var scopes = requested ?? Self.scopes(parameters["scope"] ?? resource.scopesSupported?.joined(separator: " "))
        if requested == nil { stepUps = 0 }
        if configuration.requestsOfflineAccess, !scopes.isEmpty, !scopes.contains("offline_access"),
           server.scopesSupported?.contains("offline_access") == true {
            scopes.append("offline_access")
        }
        token = nil; expiry = nil
        try Task.checkCancellation()
        let issued = try await flow.authorize(server: server, client: client, resource: resource.resource,
                                              scope: scopes.isEmpty ? nil : scopes.joined(separator: " "), userAgent: userAgent)
        try await store(issued, scopes: scopes)
    }
}
