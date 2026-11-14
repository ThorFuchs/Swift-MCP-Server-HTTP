// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import MCPHTTPClient

/// OAuth 2.1 authorization for one MCP endpoint (ADR-0006, slices A1–A4).
///
/// Give it to `HTTPClientTransport(endpoint:authorization:)`. On `401` it refreshes the token
/// when it can; otherwise it discovers the protected resource and authorization server metadata,
/// identifies the client (pre-registered, client ID metadata document or dynamic registration),
/// runs the authorization code flow with PKCE `S256`, `state`, `resource` and `iss` checks
/// through the host's user agent, and sends the token as `Authorization: Bearer`. On
/// `403 insufficient_scope` it re-authorizes with the union of the scopes it already asked
/// for and the challenged ones, within `maximumStepUps`. Concurrent challenges share one flow.
///
/// Not yet: authorization server migration and a host token store (A5).
public actor OAuthClient: HTTPClientAuthorizing {
    public let endpoint: URL
    public nonisolated let configuration: OAuthClientConfiguration
    private let userAgent: any AuthorizationUserAgent
    private let http: any AuthorizationHTTP
    private let now: @Sendable () -> ContinuousClock.Instant

    /// Discovery results and the client identity of the last authorization.
    private struct Session: Sendable {
        let resource: ProtectedResourceMetadata
        let server: AuthorizationServerMetadata
        let client: ResolvedClient
    }

    private var session: Session?
    private var token: AccessToken?
    private var expiry: ContinuousClock.Instant?
    /// The scopes the current token was requested with.
    private var requestedScopes: [String] = []
    private var stepUps = 0
    private var clients: [String: ResolvedClient] = [:]
    private var authorizing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Refresh this long before the token expires.
    static let refreshMargin: Duration = .seconds(30)

    /// - Parameters:
    ///   - endpoint: the MCP endpoint, the same URL the transport uses.
    ///   - client: used for metadata, registration and token requests; the caller owns it.
    public init(endpoint: URL, configuration: OAuthClientConfiguration, userAgent: any AuthorizationUserAgent, client: HTTPClient = .shared) {
        self.init(endpoint: endpoint, configuration: configuration, userAgent: userAgent,
                  http: AsyncHTTPClientExchange(client: client, timeout: configuration.timeout))
    }

    init(endpoint: URL, configuration: OAuthClientConfiguration, userAgent: any AuthorizationUserAgent, http: any AuthorizationHTTP,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.endpoint = endpoint; self.configuration = configuration; self.userAgent = userAgent; self.http = http; self.now = now
    }

    /// Whether the client currently holds an access token.
    public var isAuthorized: Bool { token != nil }

    /// Forgets the tokens; the next challenge starts a new authorization.
    public func signOut() { token = nil; expiry = nil; requestedScopes = []; stepUps = 0 }

    public func authorizationHeaders(for endpoint: URL) async throws -> [(name: String, value: String)] {
        guard endpoint == self.endpoint else { return [] }
        // Refresh shortly before expiry; a failed refresh leaves the token for the server to reject.
        if let expiry, now() >= expiry - Self.refreshMargin, token?.refreshToken != nil, !authorizing {
            await exclusively { _ = await self.refreshed() }
        }
        guard let token else { return [] }
        return [("Authorization", "Bearer " + token.value)]
    }

    public func handleChallenge(_ challenge: HTTPAuthorizationChallenge) async throws -> Bool {
        guard challenge.endpoint == endpoint else { return false }
        let parameters = BearerChallenge.parameters(challenge.wwwAuthenticate) ?? [:]
        switch challenge.status {
        case 401:
            if hasNewerToken(than: challenge) { return true }
            if authorizing { await waitForAuthorization(); return hasNewerToken(than: challenge) }
            return try await exclusively {
                if await self.refreshed() { return true }
                try await self.authorize(hint: parameters, scopes: nil)
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
                try await self.authorize(hint: parameters, scopes: await self.union(challenged))
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

    // MARK: Flows

    /// Uses the refresh token, if any; true when a new access token was stored.
    private func refreshed() async -> Bool {
        guard let refreshToken = token?.refreshToken, let session else { return false }
        let flow = AuthorizationFlow(http: http, configuration: configuration)
        guard let refreshed = try? await flow.refresh(refreshToken, server: session.server, client: session.client, resource: session.resource.resource) else {
            return false
        }
        store(refreshed, scopes: requestedScopes)
        return true
    }

    private func authorize(hint parameters: [String: String], scopes requested: [String]?) async throws {
        guard URLRules.isAllowed(endpoint, insecureLoopback: configuration.allowsInsecureLoopback) else {
            throw OAuthClientError.insecureURL(endpoint.absoluteString)
        }
        let discovery = Discovery(http: http, insecureLoopback: configuration.allowsInsecureLoopback, maximumBytes: configuration.maximumDocumentBytes)
        let resource = try await discovery.protectedResource(for: endpoint, hint: parameters["resource_metadata"])
        let server = try await discovery.authorizationServer(resource.authorizationServers[0])
        let flow = AuthorizationFlow(http: http, configuration: configuration)
        let client: ResolvedClient
        if let known = clients[server.issuer] { client = known }
        else { client = try await flow.client(for: server); clients[server.issuer] = client }
        session = Session(resource: resource, server: server, client: client)

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
        store(issued, scopes: scopes)
    }

    private func store(_ issued: AccessToken, scopes: [String]) {
        token = issued
        requestedScopes = scopes
        expiry = issued.expiresIn.map { now() + .seconds($0) }
    }
}
