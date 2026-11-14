// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON

/// Protected resource metadata (RFC 9728) for the MCP endpoint.
struct ProtectedResourceMetadata: Sendable, Equatable {
    /// The resource identifier exactly as published; sent unchanged as `resource`.
    let resource: String
    let authorizationServers: [String]
    let scopesSupported: [String]?
}

/// Authorization server metadata (RFC 8414 or OpenID Connect Discovery).
struct AuthorizationServerMetadata: Sendable, Equatable {
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let tokenEndpointAuthMethods: [String]?
    let scopesSupported: [String]?
    /// `authorization_response_iss_parameter_supported` (RFC 9207).
    let issParameterSupported: Bool
    let clientIDMetadataDocumentSupported: Bool
}

struct Discovery: Sendable {
    let http: any AuthorizationHTTP
    let insecureLoopback: Bool
    let maximumBytes: Int

    // MARK: Protected resource metadata

    /// Fetches the protected resource metadata: from `resource_metadata` in the challenge when
    /// present, else from the path-inserted then the root well-known URL. Checks that the
    /// published resource covers `endpoint`.
    func protectedResource(for endpoint: URL, hint: String?) async throws -> ProtectedResourceMetadata {
        for candidate in try resourceCandidates(endpoint, hint: hint) {
            let response = try await get(candidate)
            guard response.status == 200 else { continue }
            let document = try Documents.object(response.body, "protected resource metadata")
            guard let resource = document.string("resource"), let servers = document.strings("authorization_servers"), !servers.isEmpty else {
                throw OAuthClientError.invalidDocument("protected resource metadata")
            }
            guard Self.resource(resource, covers: endpoint) else {
                throw OAuthClientError.resourceMismatch(resource: resource, endpoint: endpoint.absoluteString)
            }
            return ProtectedResourceMetadata(resource: resource, authorizationServers: servers, scopesSupported: document.strings("scopes_supported"))
        }
        throw OAuthClientError.resourceMetadataNotFound(endpoint: endpoint.absoluteString)
    }

    func resourceCandidates(_ endpoint: URL, hint: String?) throws -> [URL] {
        if let hint {
            guard let url = URL(string: hint) else { throw OAuthClientError.invalidDocument("resource_metadata") }
            return [url]
        }
        guard let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false), let origin = URLRules.origin(components) else {
            throw OAuthClientError.insecureURL(endpoint.absoluteString)
        }
        let path = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        var candidates: [String] = []
        if !path.isEmpty { candidates.append("\(origin)/.well-known/oauth-protected-resource\(path)") }
        candidates.append("\(origin)/.well-known/oauth-protected-resource")
        return candidates.compactMap(URL.init(string:))
    }

    /// Whether the published resource identifier covers the endpoint: same scheme, host and
    /// port, and a path equal to the endpoint's or a parent of it on a segment boundary.
    static func resource(_ resource: String, covers endpoint: URL) -> Bool {
        guard let published = URLComponents(string: resource), let target = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              published.query == nil, published.fragment == nil,
              published.scheme?.lowercased() == target.scheme?.lowercased(),
              published.host?.lowercased() == target.host?.lowercased(),
              URLRules.effectivePort(published) == URLRules.effectivePort(target) else { return false }
        let base = published.percentEncodedPath.hasSuffix("/") ? String(published.percentEncodedPath.dropLast()) : published.percentEncodedPath
        let path = target.percentEncodedPath
        return base.isEmpty || path == base || path.hasPrefix(base + "/")
    }

    // MARK: Authorization server metadata

    /// Fetches the metadata for `issuer` from the RFC 8414 and OpenID Connect well-known URLs
    /// (path-inserted for issuers with a path) and requires its `issuer` to match exactly.
    func authorizationServer(_ issuer: String) async throws -> AuthorizationServerMetadata {
        for candidate in try serverCandidates(issuer) {
            let response = try await get(candidate)
            guard response.status == 200 else { continue }
            let document = try Documents.object(response.body, "authorization server metadata")
            let published = document.string("issuer") ?? ""
            guard published == issuer else { throw OAuthClientError.issuerMismatch(expected: issuer, actual: published) }
            guard let authorization = document.string("authorization_endpoint").flatMap(URL.init(string:)),
                  let token = document.string("token_endpoint").flatMap(URL.init(string:)) else {
                throw OAuthClientError.invalidDocument("authorization server metadata")
            }
            let registration = document.string("registration_endpoint").flatMap(URL.init(string:))
            for url in [authorization, token] + (registration.map { [$0] } ?? []) where !URLRules.isAllowed(url, insecureLoopback: insecureLoopback) {
                throw OAuthClientError.insecureURL(url.absoluteString)
            }
            guard document.strings("code_challenge_methods_supported")?.contains("S256") == true else {
                throw OAuthClientError.pkceNotSupported(issuer: issuer)
            }
            return AuthorizationServerMetadata(issuer: issuer, authorizationEndpoint: authorization, tokenEndpoint: token,
                registrationEndpoint: registration, tokenEndpointAuthMethods: document.strings("token_endpoint_auth_methods_supported"),
                scopesSupported: document.strings("scopes_supported"),
                issParameterSupported: document["authorization_response_iss_parameter_supported"]?.booleanValue == true,
                clientIDMetadataDocumentSupported: document["client_id_metadata_document_supported"]?.booleanValue == true)
        }
        throw OAuthClientError.authorizationServerMetadataNotFound(issuer: issuer)
    }

    func serverCandidates(_ issuer: String) throws -> [URL] {
        guard let url = URL(string: issuer), URLRules.isAllowed(url, insecureLoopback: insecureLoopback),
              let components = URLComponents(string: issuer), components.query == nil, components.fragment == nil,
              let origin = URLRules.origin(components) else { throw OAuthClientError.insecureURL(issuer) }
        let path = components.percentEncodedPath.hasSuffix("/") ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        let candidates = path.isEmpty
            ? ["\(origin)/.well-known/oauth-authorization-server", "\(origin)/.well-known/openid-configuration"]
            : ["\(origin)/.well-known/oauth-authorization-server\(path)", "\(origin)/.well-known/openid-configuration\(path)",
               "\(origin)\(path)/.well-known/openid-configuration"]
        return candidates.compactMap(URL.init(string:))
    }

    private func get(_ url: URL) async throws -> AuthorizationHTTPResponse {
        guard URLRules.isAllowed(url, insecureLoopback: insecureLoopback) else { throw OAuthClientError.insecureURL(url.absoluteString) }
        return try await http.send(method: "GET", url: url, headers: [("Accept", "application/json")], body: nil, maximumBytes: maximumBytes)
    }
}
