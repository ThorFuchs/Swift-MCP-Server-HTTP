// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPHTTP
import MCPProtocol
import MCPServer

/// Immutable RFC 9728 metadata, encoded once by public Swift-JSON with finite limits.
public struct ProtectedResourceMetadata: Sendable {
    public let resource:ScalarText
    public let metadataURL:String
    public let path:String
    public let response:HTTPStaticResponse
    public init(resource:ScalarText,authorizationServers:[String],scopes:[String] = []) async throws {
        guard BearerChallenge.httpsURL(resource.description),
              let parts = URLComponents(string:resource.description), parts.query == nil,
              !parts.path.contains("%"), !parts.path.contains(".."),
              !authorizationServers.isEmpty,authorizationServers.count <= 16,
              authorizationServers.allSatisfy(BearerChallenge.httpsURL),scopes.count <= 256,
              scopes.allSatisfy(BearerChallenge.validScope), scopes.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw AuthorizationMiddleware.Failure.invalidConfiguration
        }
        var metadata = parts
        metadata.path = "/.well-known/oauth-protected-resource" + (parts.path == "/" ? "" : parts.path)
        guard let url = metadata.string else { throw AuthorizationMiddleware.Failure.invalidConfiguration }
        self.resource = resource; metadataURL = url; path = metadata.path
        struct Document:Encodable {
            let resource:String, authorization_servers:[String], scopes_supported:[String], bearer_methods_supported:[String]
        }
        let budget = try RequestBudget(workUnits:8_000_000)
        try await budget.consume(UInt64(resource.description.utf8.count + authorizationServers.reduce(0) { $0 + $1.utf8.count } + scopes.reduce(0) { $0 + $1.utf8.count }) * 8 + 256)
        var limits = JSONLimits.conservative; limits[.outputBytes] = 65_536
        let value = try await budget.performJSON(limits:limits) {
            try JSONValueEncoder(options:.init(limits:$0)).encodeWithReport(
                Document(resource:resource.description,authorization_servers:authorizationServers,
                    scopes_supported:Array(Set(scopes)).sorted(),bearer_methods_supported:["header"]))
        }
        let bytes = try await budget.performJSON(limits:limits) { try JSONWriter(options:.init(limits:$0)).writeWithReport(value) }
        response = try HTTPStaticResponse(status:200,fields:[.init("Content-Type","application/json")],body:Data(bytes))
    }
}
