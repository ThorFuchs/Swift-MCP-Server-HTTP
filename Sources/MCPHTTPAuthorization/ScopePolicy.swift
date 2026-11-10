// SPDX-License-Identifier: Apache-2.0
import MCPProtocol
import MCPServer

/// Host policy for verified identities. Catalog visibility must use this same
/// policy when the dispatcher is integrated; capabilities cannot grant scopes.
public struct ScopePolicy: Sendable {
    public struct Target: Hashable, Sendable {
        public let method: WireMethod
        public let name: ScalarText
        public init(method: WireMethod, name: ScalarText) { self.method = method; self.name = name }
    }
    private let baseline: Set<ScalarText>
    private let methods: [WireMethod: Set<ScalarText>]
    private let targets: [Target: Set<ScalarText>]

    public init(baseline: Set<ScalarText>, methods: [WireMethod: Set<ScalarText>] = [:],
                targets: [Target: Set<ScalarText>] = [:]) {
        self.baseline = baseline
        self.methods = methods
        self.targets = targets
    }
    func validateConfiguration() throws {
        func valid(_ scopes:Set<ScalarText>) -> Bool {
            scopes.count <= 256 && scopes.allSatisfy { $0.description.utf8.count <= 256 && BearerChallenge.validScope($0.description) }
        }
        guard valid(baseline),methods.count <= 21,targets.count <= 1024,
              methods.values.allSatisfy(valid),targets.values.allSatisfy(valid),
              targets.keys.allSatisfy({ $0.name.description.utf8.count <= 4096 }) else {
            throw AuthorizationMiddleware.Failure.invalidConfiguration
        }
    }
    public func requiredSupplemental() -> Set<ScalarText> { baseline }
    public func required(method: WireMethod, name: ScalarText?) -> Set<ScalarText> {
        var scopes = baseline.union(methods[method] ?? [])
        if let name { scopes.formUnion(targets[Target(method: method, name: name)] ?? []) }
        return scopes
    }
    public func allows(_ principal: VerifiedPrincipal, method: WireMethod, name: ScalarText?) -> Bool {
        required(method: method, name: name).isSubset(of: principal.scopes)
    }
}
