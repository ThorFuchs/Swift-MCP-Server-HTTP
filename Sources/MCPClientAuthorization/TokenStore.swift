// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What a host persists for one MCP endpoint so authorization survives a restart: the
/// authorization server, the client identity used with it, and the tokens it issued.
///
/// Contains secrets (tokens, a client secret). Hosts store it in the Keychain or an equivalent
/// protected store; the library never writes it anywhere itself.
public struct StoredAuthorization: Sendable, Equatable {
    /// The authorization server's issuer the tokens and client belong to.
    public var issuer: String
    /// The resource identifier the tokens were issued for, as published.
    public var resource: String
    public var clientID: String
    public var clientSecret: String?
    public var authentication: TokenEndpointAuthentication
    public var accessToken: String
    public var refreshToken: String?
    /// The scopes the access token was requested with.
    public var scopes: [String]
    /// When the access token expires, if the server said.
    public var expiresAt: Date?

    public init(issuer: String, resource: String, clientID: String, clientSecret: String?, authentication: TokenEndpointAuthentication,
                accessToken: String, refreshToken: String?, scopes: [String], expiresAt: Date?) {
        self.issuer = issuer; self.resource = resource; self.clientID = clientID; self.clientSecret = clientSecret
        self.authentication = authentication; self.accessToken = accessToken; self.refreshToken = refreshToken
        self.scopes = scopes; self.expiresAt = expiresAt
    }
}

/// Host-owned persistence for authorization state, keyed by the MCP endpoint (ADR-0006).
///
/// `OAuthClient` loads once before its first request, saves after every authorization or
/// refresh, and deletes on sign-out or when the endpoint moves to another authorization server.
/// A failing store is reported to the caller; the client never falls back to a store of its own.
public protocol TokenStore: Sendable {
    func load(endpoint: URL) async throws -> StoredAuthorization?
    func save(_ authorization: StoredAuthorization, endpoint: URL) async throws
    func delete(endpoint: URL) async throws
}

/// A `TokenStore` in memory, for tests and short-lived processes.
public actor InMemoryTokenStore: TokenStore {
    private var entries: [URL: StoredAuthorization] = [:]
    public init(_ entries: [URL: StoredAuthorization] = [:]) { self.entries = entries }
    public func load(endpoint: URL) -> StoredAuthorization? { entries[endpoint] }
    public func save(_ authorization: StoredAuthorization, endpoint: URL) { entries[endpoint] = authorization }
    public func delete(endpoint: URL) { entries[endpoint] = nil }
}
