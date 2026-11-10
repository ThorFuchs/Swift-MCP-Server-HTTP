// SPDX-License-Identifier: Apache-2.0
import MCPHTTP
import MCPProtocol
import MCPServer

/// Explicit protected-resource boundary. Hosts select anonymous development
/// separately; missing/invalid credentials never trigger an automatic fallback.
public struct AuthorizationMiddleware: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case invalidConfiguration, missingToken, invalidRequest, invalidToken, insufficientScope
        public var statusCode: Int {
            switch self { case .invalidRequest: 400; case .insufficientScope: 403; default: 401 }
        }
    }
    private let verifier: any TokenVerifier
    private let resource: ScalarText
    private let issuers: Set<ScalarText>
    private let policy: ScopePolicy
    private let now: @Sendable () -> Int64

    public init(verifier: any TokenVerifier, resource: ScalarText, issuers: Set<ScalarText>,
                policy: ScopePolicy, now: @escaping @Sendable () -> Int64) throws {
        try policy.validateConfiguration()
        guard BearerChallenge.httpsURL(resource.description), !issuers.isEmpty, issuers.count <= 16,
              issuers.allSatisfy({ BearerChallenge.httpsURL($0.description) }) else {
            throw Failure.invalidConfiguration
        }
        self.verifier = verifier
        self.resource = resource
        self.issuers = issuers
        self.policy = policy
        self.now = now
    }
    public func authorize(headers: HeaderFields, method: WireMethod,
                          name: ScalarText? = nil) async throws -> VerifiedPrincipal {
        let principal = try await authenticate(headers:headers)
        try require(principal,method:method,name:name)
        return principal
    }
    public func require(_ principal:VerifiedPrincipal,method:WireMethod,name:ScalarText? = nil) throws {
        guard policy.allows(principal,method:method,name:name) else { throw Failure.insufficientScope }
    }
    public func requiredScopes(method:WireMethod,name:ScalarText? = nil) -> Set<ScalarText> {
        policy.required(method:method,name:name)
    }
    public var supplementalBaselineScopes: Set<ScalarText> { policy.requiredSupplemental() }
    public var resourceIdentity: ScalarText { resource }
    public func authenticate(headers:HeaderFields) async throws -> VerifiedPrincipal {
        try Task.checkCancellation()
        let raw: String?
        do { raw = try headers.uniqueValue("Authorization") }
        catch { throw Failure.invalidRequest }
        guard let raw else { throw Failure.missingToken }
        // Reject before copying/parsing credentials. HeaderFields independently
        // bounds the whole header population. This boundary accepts header-only
        // bearer credentials; it never chooses among duplicate carriers.
        guard raw.utf8.count <= 8192 else { throw Failure.invalidRequest }
        let bytes = Array(raw.utf8)
        guard let space = bytes.firstIndex(of: 32) else {
            if raw.lowercased() == "bearer" { throw Failure.invalidRequest }
            guard HeaderFields.validName(raw) else { throw Failure.invalidRequest }
            throw Failure.missingToken
        }
        let scheme = String(decoding: bytes[..<space], as: UTF8.self)
        guard HeaderFields.validName(scheme) else { throw Failure.invalidRequest }
        // RFC6750 section3.1: an unsupported scheme receives the normal Bearer
        // challenge without an error attribute, rather than invalid_token.
        guard scheme.lowercased() == "bearer" else { throw Failure.missingToken }
        let token = bytes.dropFirst(space).drop(while: { $0 == 32 })
        guard !token.isEmpty else { throw Failure.invalidRequest }
        var padding = false
        for byte in token {
            if byte == 61 { padding = true; continue }
            guard !padding, (48...57).contains(byte) || (65...90).contains(byte) ||
                  (97...122).contains(byte) || [45, 46, 95, 126, 43, 47].contains(byte) else {
                throw Failure.invalidRequest
            }
        }
        guard token.first != 61 else { throw Failure.invalidRequest }
        let verified: VerifiedAccessToken
        do {
            verified = try await verifier.verify(String(decoding: token, as: UTF8.self), forResource: resource)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            throw Failure.invalidToken
        }
        try Task.checkCancellation()
        guard verified.principal.resource == resource,
              issuers.contains(verified.principal.issuer), verified.expiresAtUnixSeconds > now() else {
            throw Failure.invalidToken
        }
        return verified.principal
    }
}
