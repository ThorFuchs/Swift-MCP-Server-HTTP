// SPDX-License-Identifier: Apache-2.0
import Foundation
import MCPProtocol

public enum HeaderFailure: Error, Sendable, Equatable {
    case invalidLimit, tooLarge, invalidName, invalidValue, duplicate, missing, mismatch
}

/// Strict mirror encoding from the dated Streamable HTTP value-encoding rules.
public enum HeaderMirror {
    public static func encode(_ value: String, maximumDecodedBytes: Int = 16_384) throws -> String {
        guard maximumDecodedBytes > 0 else { throw HeaderFailure.invalidLimit }
        let bytes = Array(value.utf8)
        guard bytes.count <= maximumDecodedBytes else { throw HeaderFailure.tooLarge }
        if isPlain(bytes), !sentinel(value) { return value }
        return "=?base64?" + Data(bytes).base64EncodedString() + "?="
    }
    public static func decode(_ value: String, maximumWireBytes: Int = 32_768,
                              maximumDecodedBytes: Int = 16_384) throws -> String {
        guard maximumWireBytes > 0, maximumDecodedBytes > 0 else { throw HeaderFailure.invalidLimit }
        guard value.utf8.count <= maximumWireBytes else { throw HeaderFailure.tooLarge }
        if sentinel(value) {
            let payload = String(value.dropFirst(9).dropLast(2))
            guard payload.utf8.count % 4 == 0 else { throw HeaderFailure.invalidValue }
            // Check decoded size before allocating. Padding can remove at most
            // two bytes, so use a ceiling that permits exactly the stated bound.
            let groups = payload.utf8.count / 4
            let (ceiling, overflow) = groups.multipliedReportingOverflow(by: 3)
            guard !overflow, ceiling <= maximumDecodedBytes ||
                  ceiling - maximumDecodedBytes <= 2 else { throw HeaderFailure.tooLarge }
            guard let data = Data(base64Encoded: payload), data.count <= maximumDecodedBytes,
                  data.base64EncodedString().utf8.elementsEqual(payload.utf8),
                  let text = String(data: data, encoding: .utf8) else { throw HeaderFailure.invalidValue }
            return text
        }
        guard value.utf8.count <= maximumDecodedBytes else { throw HeaderFailure.tooLarge }
        guard isPlain(Array(value.utf8)) else { throw HeaderFailure.invalidValue }
        return value
    }
    private static func sentinel(_ value: String) -> Bool {
        value.hasPrefix("=?base64?") && value.hasSuffix("?=")
    }
    private static func isPlain(_ bytes: [UInt8]) -> Bool {
        guard bytes.first != 32, bytes.first != 9, bytes.last != 32, bytes.last != 9 else { return false }
        return bytes.allSatisfy { $0 == 9 || (32...126).contains($0) }
    }
}

/// Header names are ASCII tokens and compared case-insensitively. Values retain
/// exact bytes, including duplicates; conflicting duplicates cannot pick a winner.
public struct HeaderFields: Sendable {
    public struct Field: Sendable {
        public let name: String
        public let value: String
        public init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }
    private let fields: [Field]
    public let logicalBytes: Int
    public init(_ fields: [Field], maximumCount: Int = 128, maximumBytes: Int = 32_768, allowObsoleteText: Bool = false) throws {
        guard maximumCount > 0, maximumBytes > 0 else { throw HeaderFailure.invalidLimit }
        guard fields.count <= maximumCount else { throw HeaderFailure.tooLarge }
        var weight = 0
        for field in fields {
            guard Self.validName(field.name) else { throw HeaderFailure.invalidName }
            // All field values must be safe raw HTTP bytes. OWS is allowed here;
            // recognized mirror values apply their stricter encoding policy.
            guard field.value.unicodeScalars.allSatisfy({ $0.value == 9 || (32...126).contains($0.value) || (allowObsoleteText && $0.value >= 128) }) else {
                throw HeaderFailure.invalidValue
            }
            for count in [field.name.utf8.count, field.value.utf8.count, 4] {
                guard count <= maximumBytes - weight else { throw HeaderFailure.tooLarge }
                weight += count
            }
        }
        self.fields = fields
        logicalBytes = weight
    }
    public static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ||
            [33, 35, 36, 37, 38, 39, 42, 43, 45, 46, 94, 95, 96, 124, 126].contains($0)
        }
    }
    private static func folded(_ value: String) -> [UInt8] {
        value.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }
    }
    public func value(_ name: String) throws -> String? {
        let key = Self.folded(name)
        let matches = fields.filter { Self.folded($0.name) == key }
        guard let first = matches.first else { return nil }
        guard matches.allSatisfy({ $0.value.utf8.elementsEqual(first.value.utf8) }) else {
            throw HeaderFailure.duplicate
        }
        return first.value
    }
    public func uniqueValue(_ name: String) throws -> String? {
        let key = Self.folded(name)
        let matches = fields.filter { Self.folded($0.name) == key }
        guard matches.count <= 1 else { throw HeaderFailure.duplicate }
        return matches.first?.value
    }

    /// The dispatcher supplies the exact decoded version/method/name from the body.
    public func validateMirrors(version: String, method: String, name: String?) throws {
        for (header, expected, encoded) in [
            ("MCP-Protocol-Version", version, false), ("Mcp-Method", method, false)
        ] {
            guard let raw = try value(header) else { throw HeaderFailure.missing }
            let actual = encoded ? try HeaderMirror.decode(raw) : raw
            guard actual.utf8.elementsEqual(expected.utf8) else { throw HeaderFailure.mismatch }
        }
        if let wireMethod = WireMethod(rawValue: method), wireMethod.mirroredNameField != nil {
            guard let name, let raw = try value("Mcp-Name") else { throw HeaderFailure.missing }
            guard try HeaderMirror.decode(raw).utf8.elementsEqual(name.utf8) else { throw HeaderFailure.mismatch }
        }
    }
}
