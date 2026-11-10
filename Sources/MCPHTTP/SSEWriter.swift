// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Frames already encoded UTF-8 JSON, with no event IDs or replay fields. JSON
/// validation belongs to the codec; this projection prevents delimiter injection.
public enum SSEFrame {
    public enum Failure: Error, Sendable, Equatable { case invalidLimit, tooLarge, invalidPayload }
    public static func message(_ jsonBytes: [UInt8], maximumBytes: Int = 4_194_304) throws -> [UInt8] {
        guard maximumBytes > 0 else { throw Failure.invalidLimit }
        guard maximumBytes >= 8, jsonBytes.count <= maximumBytes - 8 else { throw Failure.tooLarge }
        guard !jsonBytes.isEmpty, !jsonBytes.contains(10), !jsonBytes.contains(13),
              String(bytes: jsonBytes, encoding: .utf8) != nil else { throw Failure.invalidPayload }
        return Array("data: ".utf8) + jsonBytes + [10, 10]
    }
    public static func keepalive() -> [UInt8] { Array(": keepalive\n\n".utf8) }
}
