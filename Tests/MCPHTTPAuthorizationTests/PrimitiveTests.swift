// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPHTTPAuthorization

private struct Verifier: TokenVerifier {
    let result: VerifiedAccessToken
    func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
        #expect(bearerToken == "sentinel-secret")
        return result
    }
}
private let resource = ScalarText("https://example.com/mcp")
private let issuer = ScalarText("https://issuer.example")
private func middleware(scopes: Set<ScalarText> = ["read"].map(ScalarText.init).reduce(into: []) { $0.insert($1) },
                        expires: Int64 = 200, actualResource: ScalarText = resource,
                        actualIssuer: ScalarText = issuer) throws -> AuthorizationMiddleware {
    let principal = VerifiedPrincipal(subject: ScalarText("user"), issuer: actualIssuer,
                                      resource: actualResource, scopes: scopes)
    return try AuthorizationMiddleware(
        verifier: Verifier(result: VerifiedAccessToken(principal: principal, expiresAtUnixSeconds: expires)),
        resource: resource, issuers: [issuer], policy: ScopePolicy(baseline: [ScalarText("read")]), now: { 100 })
}

@Test func protectedAuthorizationRequiresTokenAndReturnsOnlyPrincipal() async throws {
    let auth = try middleware()
    await #expect(throws: AuthorizationMiddleware.Failure.missingToken) {
        _ = try await auth.authorize(headers: HeaderFields([]), method: .listTools)
    }
    let principal = try await auth.authorize(
        headers: HeaderFields([.init("Authorization", "bEaReR  sentinel-secret")]), method: .listTools)
    #expect(principal.subject == ScalarText("user"))
    #expect(!String(reflecting: principal).contains("sentinel-secret"))
}

@Test(arguments: ["Basic sentinel-secret", "Bearer", "Bearer ", "Bearer a b", "Bearer ===",
                  "Bearer a=b", "Bearer x\t", "Bearer é", " Bearer x"])
func malformedCredentials(_ value: String) async throws {
    let auth = try middleware()
    await #expect(throws: (any Error).self) {
        _ = try await auth.authorize(headers: HeaderFields([.init("Authorization", value)]), method: .listTools)
    }
}

@Test func identicalAuthorizationDuplicatesAreRejected() async throws {
    let auth = try middleware()
    await #expect(throws: AuthorizationMiddleware.Failure.invalidRequest) {
        _ = try await auth.authorize(headers: HeaderFields([
            .init("Authorization", "Bearer sentinel-secret"), .init("authorization", "Bearer sentinel-secret")
        ]), method: .listTools)
    }
}

@Test func expiryIssuerAndAudienceAreRechecked() async throws {
    for auth in [try middleware(expires: 100),
                 try middleware(actualResource: ScalarText("https://other.example")),
                 try middleware(actualIssuer: ScalarText("https://other-issuer.example"))] {
        await #expect(throws: AuthorizationMiddleware.Failure.invalidToken) {
            _ = try await auth.authorize(headers: HeaderFields([.init("Authorization", "Bearer sentinel-secret")]),
                                         method: .callTool, name: ScalarText("safe"))
        }
    }
}

@Test func scopesAreCheckedAndNamesRemainScalarExact() async throws {
    let auth = try middleware(scopes: [])
    await #expect(throws: AuthorizationMiddleware.Failure.insufficientScope) {
        _ = try await auth.authorize(headers: HeaderFields([.init("Authorization", "Bearer sentinel-secret")]),
                                     method: .listTools)
    }
    let policy = ScopePolicy(baseline: [], targets: [
        .init(method: .callTool, name: ScalarText("é")): [ScalarText("admin")]
    ])
    let principal = VerifiedPrincipal(subject: ScalarText("u"), issuer: issuer, resource: resource, scopes: [])
    #expect(!policy.allows(principal, method: .callTool, name: ScalarText("é")))
    #expect(policy.allows(principal, method: .callTool, name: ScalarText("e\u{301}")))
}

@Test func verifierErrorsAreRedactedAndCancellationPropagates() async throws {
    struct FailingVerifier: TokenVerifier {
        struct SecretError: Error, CustomStringConvertible {
            var description: String { "sentinel-secret" }
        }
        func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
            throw SecretError()
        }
    }
    let auth = try AuthorizationMiddleware(verifier: FailingVerifier(), resource: resource, issuers: [issuer],
        policy: ScopePolicy(baseline: []), now: { 100 })
    do {
        _ = try await auth.authorize(headers: HeaderFields([.init("Authorization", "Bearer sentinel-secret")]),
                                     method: .listTools)
        Issue.record("Verifier failure accepted")
    } catch {
        #expect(error as? AuthorizationMiddleware.Failure == .invalidToken)
        #expect(!String(reflecting: error).contains("sentinel-secret"))
    }
    struct CancelledVerifier: TokenVerifier {
        func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
            throw CancellationError()
        }
    }
    let cancelled = try AuthorizationMiddleware(verifier: CancelledVerifier(), resource: resource, issuers: [issuer],
        policy: ScopePolicy(baseline: []), now: { 100 })
    await #expect(throws: CancellationError.self) {
        _ = try await cancelled.authorize(headers: HeaderFields([.init("Authorization", "Bearer sentinel-secret")]),
                                          method: .listTools)
    }
}

@Test func challengesAreBoundedAndNeverReflectInputs() throws {
    let challenge = try BearerChallenge(metadataURL: "https://example.com/.well-known/oauth-protected-resource",
        reason: .insufficientScope, scopes: ["write", "read", "read"])
    #expect(challenge.value.hasPrefix("Bearer resource_metadata=\"https://"))
    #expect(challenge.value.contains("error=\"insufficient_scope\""))
    #expect(challenge.value.contains("scope=\"read write\""))
    #expect(throws: BearerChallenge.Failure.invalidValue) {
        _ = try BearerChallenge(metadataURL: "http://example.com")
    }
    #expect(throws: BearerChallenge.Failure.invalidValue) {
        _ = try BearerChallenge(metadataURL: "https://example.com", scopes: ["a\r\nb"])
    }
    #expect(throws: BearerChallenge.Failure.tooLarge) {
        _ = try BearerChallenge(metadataURL: "https://example.com", maximumBytes: 2)
    }
}
