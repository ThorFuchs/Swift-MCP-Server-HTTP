// SPDX-License-Identifier: Apache-2.0
import MCPProtocol
import MCPServer

/// The host owns token cryptography and checks issuer, audience, expiry, and
/// token constraints. The middleware additionally checks the returned resource,
/// issuer allowlist, and expiry. Bearer credentials never enter RequestContext.
public protocol TokenVerifier: Sendable {
    func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken
}

public struct VerifiedAccessToken: Sendable {
    public let principal: VerifiedPrincipal
    public let expiresAtUnixSeconds: Int64
    public init(principal: VerifiedPrincipal, expiresAtUnixSeconds: Int64) {
        self.principal = principal
        self.expiresAtUnixSeconds = expiresAtUnixSeconds
    }
}
