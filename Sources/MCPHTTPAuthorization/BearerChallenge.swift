// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Bounded RFC 6750 challenge. Errors have fixed public descriptions, never
/// verifier exceptions, bearer tokens, or client-supplied strings.
public struct BearerChallenge: Sendable {
    public enum Failure: Error, Sendable, Equatable { case invalidValue, tooLarge }
    public enum Reason: String, Sendable { case invalidRequest = "invalid_request", invalidToken = "invalid_token", insufficientScope = "insufficient_scope" }
    public let value: String

    public init(metadataURL: String, reason: Reason? = nil, scopes: [String] = [],
                maximumBytes: Int = 4096) throws {
        guard maximumBytes > 0, Self.httpsURL(metadataURL), scopes.allSatisfy(Self.validScope) else {
            throw Failure.invalidValue
        }
        var result = "Bearer resource_metadata=" + Self.quote(metadataURL)
        if let reason { result += ", error=" + Self.quote(reason.rawValue) }
        if !scopes.isEmpty {
            result += ", scope=" + Self.quote(Set(scopes).sorted().joined(separator: " "))
        }
        guard result.utf8.count <= maximumBytes else { throw Failure.tooLarge }
        value = result
    }
    static func httpsURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2048, value.utf8.allSatisfy({ (33...126).contains($0) }),
              !value.contains("\\"),
              let parts = URLComponents(string: value),
              parts.scheme == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { return false }
        return true
    }
    static func validScope(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { $0 == 33 || (35...91).contains($0) || (93...126).contains($0) }
    }
    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
