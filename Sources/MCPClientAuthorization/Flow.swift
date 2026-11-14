// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON

/// The identity the client uses with one authorization server.
struct ResolvedClient: Sendable, Equatable {
    let clientID: String
    let clientSecret: String?
    let authentication: TokenEndpointAuthentication
}

/// An access token for the resource.
struct AccessToken: Sendable, Equatable {
    let value: String
    let scope: String?
    let refreshToken: String?
    let expiresIn: Int?
}

struct AuthorizationFlow: Sendable {
    let http: any AuthorizationHTTP
    let configuration: OAuthClientConfiguration

    // MARK: A2: client identity

    /// A pre-registered client for the issuer, else the client ID metadata document when the
    /// server supports it, else dynamic client registration.
    func client(for server: AuthorizationServerMetadata) async throws -> ResolvedClient {
        let identity = configuration.identity
        if let registered = identity.preRegistered.first(where: { $0.issuer == server.issuer }) {
            return ResolvedClient(clientID: registered.clientID, clientSecret: registered.clientSecret,
                authentication: registered.authentication ?? Self.inferredAuthentication(secret: registered.clientSecret, server: server))
        }
        if let document = identity.metadataDocument, server.clientIDMetadataDocumentSupported {
            guard document.scheme?.lowercased() == "https", !document.path.isEmpty, document.path != "/" else {
                throw OAuthClientError.insecureURL(document.absoluteString)
            }
            return ResolvedClient(clientID: document.absoluteString, clientSecret: nil, authentication: .none)
        }
        if let registration = identity.dynamicRegistration, let endpoint = server.registrationEndpoint {
            return try await register(registration, at: endpoint, server: server)
        }
        throw OAuthClientError.noClientIdentity(issuer: server.issuer)
    }

    /// A secretless client uses `none`; otherwise `client_secret_basic` unless the server only
    /// lists `client_secret_post` (RFC 8414 defaults to `client_secret_basic`).
    static func inferredAuthentication(secret: String?, server: AuthorizationServerMetadata) -> TokenEndpointAuthentication {
        guard secret != nil else { return .none }
        let supported = server.tokenEndpointAuthMethods ?? [TokenEndpointAuthentication.clientSecretBasic.rawValue]
        if supported.contains(TokenEndpointAuthentication.clientSecretBasic.rawValue) { return .clientSecretBasic }
        if supported.contains(TokenEndpointAuthentication.clientSecretPost.rawValue) { return .clientSecretPost }
        return .clientSecretBasic
    }

    func register(_ registration: DynamicRegistration, at endpoint: URL, server: AuthorizationServerMetadata) async throws -> ResolvedClient {
        let supported = server.tokenEndpointAuthMethods ?? []
        let requested: TokenEndpointAuthentication = supported.isEmpty || supported.contains("none") ? .none
            : supported.contains(TokenEndpointAuthentication.clientSecretBasic.rawValue) ? .clientSecretBasic : .clientSecretPost
        let body = try Documents.write([
            JSONMember("client_name", value: .string(registration.clientName)),
            JSONMember("redirect_uris", value: .array([.string(configuration.redirectURI.absoluteString)])),
            JSONMember("grant_types", value: .array([.string("authorization_code"), .string("refresh_token")])),
            JSONMember("response_types", value: .array([.string("code")])),
            JSONMember("token_endpoint_auth_method", value: .string(requested.rawValue)),
            JSONMember("application_type", value: .string(registration.applicationType.rawValue)),
        ])
        let response = try await http.send(method: "POST", url: endpoint,
            headers: [("Content-Type", "application/json"), ("Accept", "application/json")], body: body,
            maximumBytes: configuration.maximumDocumentBytes)
        guard response.status == 201 || response.status == 200 else {
            let error = try? Documents.object(response.body, "registration error")
            throw OAuthClientError.registrationFailed(status: response.status, error: error?.string("error"))
        }
        let document = try Documents.object(response.body, "client registration response")
        guard let clientID = document.string("client_id"), !clientID.isEmpty else { throw OAuthClientError.invalidDocument("client registration response") }
        let secret = document.string("client_secret")
        let method = document.string("token_endpoint_auth_method").flatMap(TokenEndpointAuthentication.init(rawValue:))
            ?? Self.inferredAuthentication(secret: secret, server: server)
        return ResolvedClient(clientID: clientID, clientSecret: method == .none ? nil : secret, authentication: method)
    }

    // MARK: A3: authorization code with PKCE

    func authorize(server: AuthorizationServerMetadata, client: ResolvedClient, resource: String, scope: String?,
                   userAgent: any AuthorizationUserAgent) async throws -> AccessToken {
        let pkce = PKCE.make()
        let state = Base64URL.random()
        var parameters: [(String, String)] = [
            ("response_type", "code"), ("client_id", client.clientID),
            ("redirect_uri", configuration.redirectURI.absoluteString),
            ("code_challenge", pkce.challenge), ("code_challenge_method", "S256"),
            ("state", state), ("resource", resource),
        ]
        if let scope, !scope.isEmpty { parameters.append(("scope", scope)) }
        let url = try Self.appending(parameters, to: server.authorizationEndpoint)
        let redirect = try await userAgent.authorize(AuthorizationRequest(url: url, redirectURI: configuration.redirectURI, issuer: server.issuer))
        let code = try Self.code(from: redirect, expected: configuration.redirectURI, state: state, server: server)
        return try await exchange(code: code, verifier: pkce.verifier, server: server, client: client, resource: resource)
    }

    static func appending(_ parameters: [(String, String)], to endpoint: URL) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), components.fragment == nil else {
            throw OAuthClientError.invalidDocument("authorization_endpoint")
        }
        let added = FormEncoding.encode(parameters)
        components.percentEncodedQuery = components.percentEncodedQuery.map { $0.isEmpty ? added : $0 + "&" + added } ?? added
        guard let url = components.url else { throw OAuthClientError.invalidDocument("authorization_endpoint") }
        return url
    }

    /// Validates the authorization response: the redirect URI, `error`, `state` and `iss`
    /// (RFC 9207: compared by exact string when present, required when advertised).
    static func code(from redirect: URL, expected: URL, state: String, server: AuthorizationServerMetadata) throws -> String {
        guard let received = URLComponents(url: redirect, resolvingAgainstBaseURL: false),
              let registered = URLComponents(url: expected, resolvingAgainstBaseURL: false),
              received.scheme?.lowercased() == registered.scheme?.lowercased(), received.host?.lowercased() == registered.host?.lowercased(),
              received.port == registered.port, received.percentEncodedPath == registered.percentEncodedPath else {
            throw OAuthClientError.invalidRedirect("the redirect does not match the redirect URI")
        }
        var values: [String: String] = [:]
        for item in received.queryItems ?? [] where values[item.name] == nil { values[item.name] = item.value ?? "" }
        if let error = values["error"] { throw OAuthClientError.authorizationDenied(error: error, description: values["error_description"]) }
        guard values["state"] == state else { throw OAuthClientError.stateMismatch }
        if let issuer = values["iss"] {
            guard issuer == server.issuer else { throw OAuthClientError.issuerParameterMismatch(expected: server.issuer, actual: issuer) }
        } else if server.issParameterSupported {
            throw OAuthClientError.issuerParameterMissing
        }
        guard let code = values["code"], !code.isEmpty else { throw OAuthClientError.invalidRedirect("the redirect has no code") }
        return code
    }

    func exchange(code: String, verifier: String, server: AuthorizationServerMetadata, client: ResolvedClient, resource: String) async throws -> AccessToken {
        var parameters: [(String, String)] = [
            ("grant_type", "authorization_code"), ("code", code),
            ("redirect_uri", configuration.redirectURI.absoluteString),
            ("code_verifier", verifier), ("resource", resource),
        ]
        var headers: [(name: String, value: String)] = [("Content-Type", "application/x-www-form-urlencoded"), ("Accept", "application/json")]
        switch client.authentication {
        case .none:
            parameters.append(("client_id", client.clientID))
        case .clientSecretPost:
            parameters.append(("client_id", client.clientID))
            parameters.append(("client_secret", client.clientSecret ?? ""))
        case .clientSecretBasic:
            // RFC 6749 §2.3.1: both parts are form-encoded before Base64.
            let credentials = FormEncoding.escape(client.clientID) + ":" + FormEncoding.escape(client.clientSecret ?? "")
            headers.append(("Authorization", "Basic " + Data(credentials.utf8).base64EncodedString()))
        }
        let response = try await http.send(method: "POST", url: server.tokenEndpoint, headers: headers,
            body: Array(FormEncoding.encode(parameters).utf8), maximumBytes: configuration.maximumDocumentBytes)
        guard response.status == 200 else {
            let error = try? Documents.object(response.body, "token error")
            throw OAuthClientError.tokenRequestFailed(status: response.status, error: error?.string("error"), description: error?.string("error_description"))
        }
        let document = try Documents.object(response.body, "token response")
        guard let value = document.string("access_token"), !value.isEmpty, let type = document.string("token_type") else {
            throw OAuthClientError.invalidDocument("token response")
        }
        guard type.lowercased() == "bearer" else { throw OAuthClientError.unsupportedTokenType(type) }
        return AccessToken(value: value, scope: document.string("scope"), refreshToken: document.string("refresh_token"),
            expiresIn: try? document["expires_in"]?.numberValue?.integer(as: Int.self))
    }
}
