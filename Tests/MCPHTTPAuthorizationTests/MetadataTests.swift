// SPDX-License-Identifier: Apache-2.0
import Testing
import MCPProtocol
import MCPHTTP
import MCPHTTPAuthorization
import MCPServer

@Test func protectedMetadataRejectsUnsafeResourceAndIssuerConfigurations() async throws {
    for resource in ["http://example.com/mcp","https://user@example.com/mcp","https://example.com/mcp#fragment","https://example.com/mcp?token=secret"] {
        await #expect(throws:AuthorizationMiddleware.Failure.invalidConfiguration) {
            _ = try await ProtectedResourceMetadata(resource:ScalarText(resource),authorizationServers:["https://issuer.example"])
        }
    }
    await #expect(throws:AuthorizationMiddleware.Failure.invalidConfiguration) {
        _ = try await ProtectedResourceMetadata(resource:ScalarText("https://example.com/mcp"),authorizationServers:[])
    }
    let metadata = try await ProtectedResourceMetadata(resource:ScalarText("https://example.com/api/mcp"),authorizationServers:["https://issuer.example"])
    #expect(metadata.path == "/.well-known/oauth-protected-resource/api/mcp" && metadata.response.body.count > 0)
}

@Test func scopeChallengesRemainDenialsWhenCatalogHintsExceedHeaderBounds() async throws {
    let resource = ScalarText("https://example.com/mcp")
    let middleware = try AuthorizationMiddleware(verifier:UnusedMetadataVerifier(),resource:resource,issuers:[ScalarText("https://issuer.example")],policy:ScopePolicy(baseline:[]),now:{1000})
    let metadata = try await ProtectedResourceMetadata(resource:resource,authorizationServers:["https://issuer.example"])
    let policy = try HTTPAuthorizationPolicy(middleware:middleware,metadata:metadata)
    let principal = VerifiedPrincipal(subject:ScalarText("one"),issuer:ScalarText("https://issuer.example"),resource:resource,scopes:[])
    for scopes:Set<ScalarText> in [[ScalarText("unsafe scope")], Set((0..<256).map { ScalarText(String(repeating:"x",count:32)+String($0)) })] {
        do { try policy.authorize(principal,requiredScopes:scopes); Issue.record("Scope denial was bypassed") }
        catch let denial as HTTPAccessFailure {
            #expect(denial.response.status == 403 && denial.response.body.isEmpty)
            #expect(denial.response.fields.first?.value.contains("insufficient_scope") == true)
            #expect(denial.response.fields.first?.value.contains(", scope=") == false)
        }
    }
}

private struct UnusedMetadataVerifier:TokenVerifier {
    func verify(_ bearerToken:String,forResource resource:ScalarText) async throws -> VerifiedAccessToken { throw CancellationError() }
}
