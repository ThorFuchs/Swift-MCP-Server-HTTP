// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPHTTPAuthorization

private actor StatusVerifier: TokenVerifier {
    enum Outcome: Sendable { case valid, invalid, cancelled }
    struct Rejection: Error { let privateDetail = "private-verifier-detail" }
    let outcome: Outcome
    private(set) var calls = 0
    init(_ outcome: Outcome = .valid) { self.outcome = outcome }
    func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
        calls += 1
        switch outcome {
        case .invalid: throw Rejection()
        case .cancelled: throw CancellationError()
        case .valid:
            return .init(principal: .init(subject: ScalarText("user"), issuer: ScalarText("https://issuer.example"), resource: resource, scopes: []), expiresAtUnixSeconds: 200)
        }
    }
}
private func statusPolicy(_ verifier: StatusVerifier) async throws -> HTTPAuthorizationPolicy {
    let resource = ScalarText("https://example.com/mcp")
    let middleware = try AuthorizationMiddleware(verifier: verifier, resource: resource,
        issuers: [ScalarText("https://issuer.example")], policy: ScopePolicy(baseline: []), now: { 100 })
    let metadata = try await ProtectedResourceMetadata(resource: resource, authorizationServers: ["https://issuer.example"])
    return try HTTPAuthorizationPolicy(middleware: middleware, metadata: metadata)
}
private func statusDenial(_ policy: HTTPAuthorizationPolicy, _ headers: HeaderFields) async throws -> HTTPStaticResponse {
    do {
        _ = try await policy.authenticate(headers: headers)
        Issue.record("Expected authentication denial")
        throw AuthorizationMiddleware.Failure.invalidConfiguration
    } catch let failure as HTTPAccessFailure { return failure.response }
}
private func statusChallenge(_ response: HTTPStaticResponse) throws -> String {
    #expect(response.body.isEmpty)
    return try #require(response.fields.first(where: { $0.name.lowercased() == "www-authenticate" })?.value)
}

@Test(arguments: ["Bearer", "Bearer ", "Bearer a b", "Bearer ===", "Bearer a=b", "Bearer x\t", " Bearer x", "Bearer é"])
func malformedBearerRequestReturns400BeforeVerifier(_ text: String) async throws {
    let verifier = StatusVerifier(), policy = try await statusPolicy(verifier)
    let response = try await statusDenial(policy, HeaderFields([.init("Authorization", text)], allowObsoleteText: true))
    #expect(response.status == 400)
    let challenge = try statusChallenge(response)
    #expect(challenge.contains("error=\"invalid_request\""))
    #expect(challenge.contains("resource_metadata=\"https://example.com/.well-known/oauth-protected-resource/mcp\""))
    #expect(challenge == "Bearer resource_metadata=\"https://example.com/.well-known/oauth-protected-resource/mcp\", error=\"invalid_request\"")
    #expect(await verifier.calls == 0)
}

@Test func duplicateCredentialsNeverSelectAWinningToken() async throws {
    let verifier = StatusVerifier(), policy = try await statusPolicy(verifier)
    for second in ["Bearer sentinel-secret", "Bearer different-secret", "Basic credentials"] {
        let response = try await statusDenial(policy, HeaderFields([
            .init("Authorization", "Bearer sentinel-secret"), .init("authorization", second)]))
        #expect(response.status == 400)
        let challenge = try statusChallenge(response)
        #expect(challenge.contains("error=\"invalid_request\""))
        #expect(!challenge.contains("sentinel-secret") && !challenge.contains("different-secret"))
    }
    #expect(await verifier.calls == 0)
}

@Test func missingAndUnsupportedCredentialsGetAnUnadorned401Challenge() async throws {
    let verifier = StatusVerifier(), policy = try await statusPolicy(verifier)
    for headers in [try HeaderFields([]), try HeaderFields([.init("Authorization", "Basic credentials")]), try HeaderFields([.init("Authorization", "Digest")])] {
        let response = try await statusDenial(policy, headers)
        #expect(response.status == 401)
        #expect(!(try statusChallenge(response)).contains("error="))
    }
    #expect(await verifier.calls == 0)
}

@Test func invalidVerifiedTokenRemains401AndScopeDenialRemains403() async throws {
    let rejected = StatusVerifier(.invalid), policy = try await statusPolicy(rejected)
    let response = try await statusDenial(policy, HeaderFields([.init("Authorization", "Bearer sentinel-secret")]))
    let invalidChallenge = try statusChallenge(response)
    #expect(response.status == 401 && invalidChallenge.contains("error=\"invalid_token\""))
    #expect(!(try statusChallenge(response)).contains("private-verifier-detail"))
    #expect(!(try statusChallenge(response)).contains("sentinel-secret"))
    #expect(await rejected.calls == 1)
    let valid = StatusVerifier(), protected = try await statusPolicy(valid)
    let principal = try await protected.authenticate(headers: HeaderFields([.init("Authorization", "Bearer sentinel-secret")]))
    do { try protected.authorize(principal, requiredScopes: [ScalarText("write")]); Issue.record("Scope denial bypassed") }
    catch let failure as HTTPAccessFailure {
        #expect(failure.response.status == 403)
        let challenge = try statusChallenge(failure.response)
        #expect(challenge.contains("error=\"insufficient_scope\"") && challenge.contains("scope=\"write\""))
    }
}

@Test func authorizationByteCeilingIsCheckedBeforeVerification() async throws {
    let verifier = StatusVerifier(), policy = try await statusPolicy(verifier)
    let exact = "Bearer " + String(repeating: "x", count: 8185)
    _ = try await policy.authenticate(headers: HeaderFields([.init("Authorization", exact)]))
    #expect(await verifier.calls == 1)
    let denied = try await statusDenial(policy, HeaderFields([.init("Authorization", exact + "x")]))
    let deniedChallenge = try statusChallenge(denied)
    #expect(denied.status == 400 && deniedChallenge.contains("invalid_request"))
    #expect(await verifier.calls == 1)
}

@Test func policyDoesNotConvertVerifierCancellationIntoAnHTTPDenial() async throws {
    let verifier = StatusVerifier(.cancelled), policy = try await statusPolicy(verifier)
    await #expect(throws: CancellationError.self) {
        _ = try await policy.authenticate(headers: HeaderFields([.init("Authorization", "Bearer sentinel-secret")]))
    }
    #expect(await verifier.calls == 1)
}
