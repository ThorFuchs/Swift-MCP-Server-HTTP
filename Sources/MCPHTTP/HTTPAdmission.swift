// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Transport admission over bounded raw headers, before reading/decoding a body.
public struct HTTPAdmission: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        case invalidConfiguration, notFound, methodNotAllowed, unsupportedMediaType, notAcceptable, malformed, tooLarge
        public var statusCode: Int {
            switch self {
            case .notFound: 404
            case .methodNotAllowed: 405
            case .unsupportedMediaType: 415
            case .notAcceptable: 406
            case .tooLarge: 413
            default: 400
            }
        }
    }
    public let endpoint: String
    public let maximumBodyBytes: Int

    public init(endpoint: String = "/mcp", maximumBodyBytes: Int = 1_048_576) throws {
        guard endpoint.hasPrefix("/"), endpoint.utf8.allSatisfy({ (33...126).contains($0) }),
              !endpoint.contains("?"), !endpoint.contains("#"), maximumBodyBytes > 0 else {
            throw Failure.invalidConfiguration
        }
        self.endpoint = endpoint
        self.maximumBodyBytes = maximumBodyBytes
    }

    public func validate(method: String, path: String, headers: HeaderFields) throws {
        guard path.utf8.elementsEqual(endpoint.utf8) else { throw Failure.notFound }
        guard method == "POST" else { throw Failure.methodNotAllowed }
        guard let contentType = try headers.uniqueValue("Content-Type") else { throw Failure.unsupportedMediaType }
        let type = contentType.split(separator: ";", omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard type == "application/json" else { throw Failure.unsupportedMediaType }
        guard let accept = try headers.value("Accept") else { throw Failure.notAcceptable }
        var accepted: Set<String> = []
        for entry in accept.split(separator: ",", omittingEmptySubsequences: false) {
            let pieces = entry.split(separator: ";", omittingEmptySubsequences: false)
            let media = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard !media.isEmpty else { throw Failure.malformed }
            var quality: Int?
            for parameter in pieces.dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard pair.count == 2 else { throw Failure.malformed }
                if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "q" {
                    guard quality == nil else { throw Failure.malformed }
                    quality = try Self.quality(pair[1].trimmingCharacters(in: .whitespaces))
                }
            }
            if (quality ?? 1000) > 0 { accepted.insert(media) }
        }
        guard accepted.contains("application/json"), accepted.contains("text/event-stream") else {
            throw Failure.notAcceptable
        }
        if let length = try headers.uniqueValue("Content-Length") {
            guard !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
                  let count = Int(length) else { throw Failure.malformed }
            guard count <= maximumBodyBytes else { throw Failure.tooLarge }
        }
    }

    private static func quality(_ value: String) throws -> Int {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, first == 48 || first == 49 else { throw Failure.malformed }
        if bytes.count == 1 { return first == 49 ? 1000 : 0 }
        guard bytes.count <= 5, bytes[1] == 46,
              bytes.dropFirst(2).allSatisfy({ (48...57).contains($0) }),
              first == 48 || bytes.dropFirst(2).allSatisfy({ $0 == 48 }) else { throw Failure.malformed }
        if first == 49 { return 1000 }
        let fraction = String(decoding: bytes.dropFirst(2), as: UTF8.self)
        return Int(fraction.padding(toLength: 3, withPad: "0", startingAt: 0)) ?? 0
    }
}
