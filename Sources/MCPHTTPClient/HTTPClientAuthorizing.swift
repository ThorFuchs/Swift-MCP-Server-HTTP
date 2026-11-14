// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Supplies credentials for `HTTPClientTransport` and answers authorization challenges
/// (ADR-0006). `MCPClientAuthorization.OAuthClient` implements it; hosts may supply their own.
public protocol HTTPClientAuthorizing: Sendable {
    /// Headers for the next request to `endpoint`, for example `Authorization: Bearer …`.
    func authorizationHeaders(for endpoint: URL) async throws -> [(name: String, value: String)]

    /// Called when a request is answered with `401` or `403`. Returns true when new
    /// credentials are available and the transport should send the request once more; throws
    /// when authorization failed. The transport retries a request at most once.
    func handleChallenge(_ challenge: HTTPAuthorizationChallenge) async throws -> Bool
}

/// A rejected request: the status, its `WWW-Authenticate` values and the credentials it carried.
public struct HTTPAuthorizationChallenge: Sendable, Equatable {
    public let endpoint: URL
    public let status: Int
    /// Every `WWW-Authenticate` header value, in order.
    public let wwwAuthenticate: [String]
    /// The `Authorization` header value the rejected request carried, if any. Lets a handler
    /// see that another request already replaced the rejected credentials.
    public let sentAuthorization: String?

    public init(endpoint: URL, status: Int, wwwAuthenticate: [String], sentAuthorization: String?) {
        self.endpoint = endpoint; self.status = status
        self.wwwAuthenticate = wwwAuthenticate; self.sentAuthorization = sentAuthorization
    }
}
