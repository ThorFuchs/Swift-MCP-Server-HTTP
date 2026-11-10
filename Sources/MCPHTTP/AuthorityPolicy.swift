// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Exact ASCII allowlists for effective authority and Origin. Forwarded headers
/// confer no trust in this policy; a future trusted-proxy adapter must separately
/// prove the peer and pass the effective authority explicitly.
public struct AuthorityPolicy: Sendable {
    public enum Failure: Error, Sendable, Equatable { case invalidConfiguration, forbidden }
    /// Exact matching is the default. A host may explicitly permit its verified
    /// listener port on an otherwise port-free allowed hostname (including port 0
    /// listeners). The transport supplies the actual bound local port, never a
    /// forwarded header or a client-supplied value.
    public enum PortPolicy: Sendable { case exact, boundListener }
    private let authorities: Set<String>
    private let origins: Set<String>
    private let listenerHosts: Set<String>
    private let portPolicy: PortPolicy
    private let originPortPolicy: PortPolicy

    public init(authorities: [String], origins: [String], portPolicy: PortPolicy = .exact,
                originPortPolicy: PortPolicy = .exact) throws {
        guard !authorities.isEmpty, authorities.count <= 128, origins.count <= 128 else {
            throw Failure.invalidConfiguration
        }
        guard authorities.allSatisfy(Self.validAuthority), origins.allSatisfy(Self.validOrigin) else {
            throw Failure.invalidConfiguration
        }
        self.authorities = Set(authorities.map { $0.lowercased() })
        self.origins = Set(origins.map { $0.lowercased() })
        self.listenerHosts = Set(authorities.compactMap {
            let parts = URLComponents(string: "https://" + $0)
            return parts?.port == nil ? parts?.host?.lowercased() : nil
        })
        self.portPolicy = portPolicy
        self.originPortPolicy = originPortPolicy
    }
    public func validate(authority: String, origin: String?, boundPort: Int? = nil) throws {
        guard Self.validAuthority(authority) else { throw Failure.forbidden }
        var permitted = authorities.contains(authority.lowercased())
        if !permitted, portPolicy == .boundListener, let boundPort, (1...65535).contains(boundPort),
           let parsed = URLComponents(string: "https://" + authority), parsed.port == boundPort,
           let host = parsed.host, listenerHosts.contains(host.lowercased()) { permitted = true }
        guard permitted else {
            throw Failure.forbidden
        }
        if let origin {
            guard Self.validOrigin(origin) else { throw Failure.forbidden }
            var permittedOrigin = origins.contains(origin.lowercased())
            if !permittedOrigin, originPortPolicy == .boundListener, let boundPort,
               (1...65535).contains(boundPort), var parsed = URLComponents(string: origin),
               parsed.port == boundPort {
                parsed.port = nil
                permittedOrigin = parsed.string.map { origins.contains($0.lowercased()) } ?? false
            }
            guard permittedOrigin else { throw Failure.forbidden }
        }
    }
    private static func validAuthority(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1024,
              value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains("@"), !value.contains("%"), !value.contains("\\"),
              !value.contains("/"), !value.contains("?"), !value.contains("#"),
              let parts = URLComponents(string: "https://" + value),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return false }
        return !host.hasSuffix(".")
    }
    private static func validOrigin(_ value: String) -> Bool {
        guard let separator = value.range(of: "://"),
              ["https", "http"].contains(String(value[..<separator.lowerBound]).lowercased()) else { return false }
        return validAuthority(String(value[separator.upperBound...]))
    }
}
