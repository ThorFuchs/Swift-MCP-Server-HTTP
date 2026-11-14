// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

/// Presents the authorization request to the user (ADR-0006). Hosts use
/// `ASWebAuthenticationSession`, a loopback listener or a device-specific flow; the library
/// supplies none.
public protocol AuthorizationUserAgent: Sendable {
    /// Opens `request.url` and returns the URL the authorization server redirected to, which
    /// starts with `request.redirectURI`. Throwing cancels the authorization.
    func authorize(_ request: AuthorizationRequest) async throws -> URL
}

/// One authorization request for the user agent.
public struct AuthorizationRequest: Sendable, Equatable {
    /// The authorization endpoint with every parameter.
    public let url: URL
    /// The redirect URI the response will come back to.
    public let redirectURI: URL
    /// The authorization server's issuer, for display.
    public let issuer: String
}

/// How the client authenticates at the token endpoint.
public enum TokenEndpointAuthentication: String, Sendable, CaseIterable {
    case none
    case clientSecretBasic = "client_secret_basic"
    case clientSecretPost = "client_secret_post"
}

/// A client registered with an authorization server out of band.
public struct PreRegisteredClient: Sendable, Equatable {
    /// The issuer the registration belongs to, compared exactly with the metadata's `issuer`.
    public var issuer: String
    public var clientID: String
    public var clientSecret: String?
    /// The registered method; inferred from the secret and the server's metadata when nil.
    public var authentication: TokenEndpointAuthentication?

    public init(issuer: String, clientID: String, clientSecret: String? = nil, authentication: TokenEndpointAuthentication? = nil) {
        self.issuer = issuer; self.clientID = clientID; self.clientSecret = clientSecret; self.authentication = authentication
    }
}

/// How the client identifies itself, tried in this order: a pre-registered client for the
/// issuer, a client ID metadata document when the server supports it, then dynamic client
/// registration (RFC 7591) when allowed.
public struct ClientIdentity: Sendable, Equatable {
    public var preRegistered: [PreRegisteredClient]
    /// An `https` URL serving the client ID metadata document; used as `client_id`.
    public var metadataDocument: URL?
    /// Registration details for dynamic client registration; nil disables it.
    public var dynamicRegistration: DynamicRegistration?

    public init(preRegistered: [PreRegisteredClient] = [], metadataDocument: URL? = nil, dynamicRegistration: DynamicRegistration? = nil) {
        self.preRegistered = preRegistered; self.metadataDocument = metadataDocument; self.dynamicRegistration = dynamicRegistration
    }
}

/// What the client sends in a dynamic client registration request.
public struct DynamicRegistration: Sendable, Equatable {
    public enum ApplicationType: String, Sendable { case native, web }
    public var clientName: String
    public var applicationType: ApplicationType
    public init(clientName: String, applicationType: ApplicationType = .native) {
        self.clientName = clientName; self.applicationType = applicationType
    }
}

public struct OAuthClientConfiguration: Sendable {
    public var identity: ClientIdentity
    /// The redirect URI registered for this client; compared exactly with the redirect.
    public var redirectURI: URL
    /// Allows `http` to loopback hosts for every authorization URL. Development only.
    public var allowsInsecureLoopback: Bool
    /// Upper bound for every metadata, registration and token response body.
    public var maximumDocumentBytes: Int
    /// Deadline of each request to an authorization or resource server.
    public var timeout: TimeAmount
    /// Adds `offline_access` to the requested scopes when the authorization server lists it,
    /// to obtain a refresh token (SEP-2207).
    public var requestsOfflineAccess: Bool
    /// How many `403 insufficient_scope` step-ups may follow one another before the client
    /// stops asking the user; a fresh `401` authorization resets the count.
    public var maximumStepUps: Int

    public init(identity: ClientIdentity, redirectURI: URL, allowsInsecureLoopback: Bool = false,
                maximumDocumentBytes: Int = 64 * 1024, timeout: TimeAmount = .seconds(30),
                requestsOfflineAccess: Bool = true, maximumStepUps: Int = 3) {
        self.identity = identity; self.redirectURI = redirectURI; self.allowsInsecureLoopback = allowsInsecureLoopback
        self.maximumDocumentBytes = maximumDocumentBytes; self.timeout = timeout
        self.requestsOfflineAccess = requestsOfflineAccess; self.maximumStepUps = maximumStepUps
    }
}

/// Why authorization failed. Every case stops the flow before credentials or codes are sent
/// anywhere they should not go.
public enum OAuthClientError: Error, Sendable, Equatable {
    /// A URL is neither `https` nor an allowed development loopback URL.
    case insecureURL(String)
    case documentTooLarge(String)
    case invalidDocument(String)
    case resourceMetadataNotFound(endpoint: String)
    /// The protected resource metadata names a resource that does not cover the endpoint.
    case resourceMismatch(resource: String, endpoint: String)
    case authorizationServerMetadataNotFound(issuer: String)
    /// The metadata's `issuer` is not exactly the issuer it was discovered for.
    case issuerMismatch(expected: String, actual: String)
    /// The server does not advertise PKCE with `S256`.
    case pkceNotSupported(issuer: String)
    case noClientIdentity(issuer: String)
    case registrationFailed(status: Int, error: String?)
    /// The redirect does not match the redirect URI or lacks a code.
    case invalidRedirect(String)
    case authorizationDenied(error: String, description: String?)
    case stateMismatch
    /// The server advertises `iss` in authorization responses (RFC 9207), but it is missing.
    case issuerParameterMissing
    case issuerParameterMismatch(expected: String, actual: String)
    case tokenRequestFailed(status: Int, error: String?, description: String?)
    case unsupportedTokenType(String)
}
