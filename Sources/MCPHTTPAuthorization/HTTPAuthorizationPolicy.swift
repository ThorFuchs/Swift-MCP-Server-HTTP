// SPDX-License-Identifier: Apache-2.0
import MCPHTTP
import MCPProtocol
import MCPServer

/// Protected policy for the production HTTP adapter. Host verifier failures are
/// fixed challenges; no token or verifier description is reflected or forwarded.
public struct HTTPAuthorizationPolicy: HTTPAccessPolicy {
    private let middleware:AuthorizationMiddleware, document:ProtectedResourceMetadata
    private let missing:HTTPStaticResponse, malformed:HTTPStaticResponse, invalid:HTTPStaticResponse, insufficient:HTTPStaticResponse
    public init(middleware:AuthorizationMiddleware,metadata:ProtectedResourceMetadata) throws {
        guard middleware.resourceIdentity == metadata.resource else { throw AuthorizationMiddleware.Failure.invalidConfiguration }
        self.middleware = middleware; document = metadata
        missing = try Self.rejection(metadataURL:metadata.metadataURL,reason:nil,scopes:[],status:401)
        malformed = try Self.rejection(metadataURL:metadata.metadataURL,reason:.invalidRequest,scopes:[],status:400)
        invalid = try Self.rejection(metadataURL:metadata.metadataURL,reason:.invalidToken,scopes:[],status:401)
        insufficient = try Self.rejection(metadataURL:metadata.metadataURL,reason:.insufficientScope,scopes:[],status:403)
    }
    public func authenticate(headers:HeaderFields) async throws -> VerifiedPrincipal {
        do { return try await middleware.authenticate(headers:headers) }
        catch let error as AuthorizationMiddleware.Failure {
            switch error {
            case .missingToken: throw HTTPAccessFailure(response:missing)
            case .invalidRequest: throw HTTPAccessFailure(response:malformed)
            default: throw HTTPAccessFailure(response:invalid)
            }
        }
    }
    public func authorize(_ principal:VerifiedPrincipal,method:WireMethod,name:ScalarText?) throws {
        do { try middleware.require(principal,method:method,name:name) }
        catch let error as AuthorizationMiddleware.Failure where error == .insufficientScope {
            let scopes = middleware.requiredScopes(method:method,name:name).map(\.description)
            throw HTTPAccessFailure(response:scopeRejection(scopes))
        }
    }
    public func authorizeSupplemental(_ principal: VerifiedPrincipal, method: ScalarText) throws {
        try authorize(principal, requiredScopes: middleware.supplementalBaselineScopes)
    }
    public func authorize(_ principal:VerifiedPrincipal,requiredScopes:Set<ScalarText>) throws {
        guard requiredScopes.isSubset(of:principal.scopes) else {
            throw HTTPAccessFailure(response:scopeRejection(requiredScopes.map(\.description)))
        }
    }
    private func scopeRejection(_ scopes:[String]) -> HTTPStaticResponse {
        // RFC6750 scope hints are optional. An invalid/oversized catalog hint
        // must still deny access, without reflecting it or replacing 403 by 500.
        (try? Self.rejection(metadataURL:document.metadataURL,reason:.insufficientScope,scopes:scopes,status:403)) ?? insufficient
    }
    public func metadata(path:String) -> HTTPStaticResponse? {
        path.utf8.elementsEqual(document.path.utf8) ? document.response : nil
    }
    private static func rejection(metadataURL:String,reason:BearerChallenge.Reason?,scopes:[String],status:Int) throws -> HTTPStaticResponse {
        try .init(status:status,fields:[.init("WWW-Authenticate",BearerChallenge(metadataURL:metadataURL,reason:reason,scopes:scopes).value)])
    }
}
