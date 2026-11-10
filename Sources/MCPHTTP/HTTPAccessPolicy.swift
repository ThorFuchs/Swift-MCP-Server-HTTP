// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol
import MCPServer

/// Bounded ordinary HTTP response for host policy and metadata routing.
public struct HTTPStaticResponse: Sendable {
    public let status: Int
    public let fields: [HeaderFields.Field]
    public let body: Data
    public init(status: Int, fields: [HeaderFields.Field] = [], body: Data = Data()) throws {
        guard (200...599).contains(status), body.count <= 65_536 else { throw HTTPAdmission.Failure.invalidConfiguration }
        let framing:Set<String> = ["content-length","transfer-encoding","connection","trailer","upgrade","keep-alive"]
        guard fields.allSatisfy({ !framing.contains($0.name.lowercased()) }) else { throw HTTPAdmission.Failure.invalidConfiguration }
        _ = try HeaderFields(fields, maximumCount: 32, maximumBytes: 8192)
        self.status = status; self.fields = fields; self.body = body
    }
}
public struct HTTPAccessFailure: RequestAccessFailure, Sendable {
    public let response: HTTPStaticResponse
    public init(response: HTTPStaticResponse) { self.response = response }
}
/// Host-injected resource-server policy. Credentials never enter the core or providers.
public protocol HTTPAccessPolicy: Sendable {
    func authenticate(headers: HeaderFields) async throws -> VerifiedPrincipal
    func authorize(_ principal: VerifiedPrincipal, method: WireMethod, name: ScalarText?) throws
    func authorizeSupplemental(_ principal: VerifiedPrincipal, method: ScalarText) throws
    func authorize(_ principal: VerifiedPrincipal, requiredScopes:Set<ScalarText>) throws
    func metadata(path: String) -> HTTPStaticResponse?
}

extension HTTPAccessPolicy {
    /// Older host policies must explicitly opt into new supplemental routes.
    public func authorizeSupplemental(_ principal: VerifiedPrincipal, method: ScalarText) throws {
        throw HTTPAccessFailure(response: try .init(status: 403))
    }
    public func authorize(_ principal:VerifiedPrincipal,requiredScopes:Set<ScalarText>) throws {
        guard requiredScopes.isSubset(of:principal.scopes) else { throw HTTPAccessFailure(response:try .init(status:403)) }
    }
}
