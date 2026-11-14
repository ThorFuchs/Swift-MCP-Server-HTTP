// SPDX-License-Identifier: Apache-2.0
import AsyncHTTPClient
import Foundation
import JSON
import MCPProtocol
import NIOCore
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: HTTP

/// One response from an authorization or resource server, with a bounded body.
struct AuthorizationHTTPResponse: Sendable {
    let status: Int
    let headers: [(name: String, value: String)]
    let body: [UInt8]
    func header(_ name: String) -> String? { headers.first { $0.name.lowercased() == name.lowercased() }?.value }
}

/// The HTTP exchanges the OAuth client makes. Tests substitute an in-memory server.
protocol AuthorizationHTTP: Sendable {
    func send(method: String, url: URL, headers: [(name: String, value: String)], body: [UInt8]?, maximumBytes: Int) async throws -> AuthorizationHTTPResponse
}

struct AsyncHTTPClientExchange: AuthorizationHTTP {
    let client: HTTPClient
    let timeout: TimeAmount

    func send(method: String, url: URL, headers: [(name: String, value: String)], body: [UInt8]?, maximumBytes: Int) async throws -> AuthorizationHTTPResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = method == "POST" ? .POST : .GET
        for header in headers { request.headers.add(name: header.name, value: header.value) }
        if let body { request.body = .bytes(ByteBuffer(bytes: body)) }
        let response = try await client.execute(request, timeout: timeout)
        let collected: ByteBuffer
        do { collected = try await response.body.collect(upTo: maximumBytes) }
        catch is NIOTooManyBytesError { throw OAuthClientError.documentTooLarge(url.absoluteString) }
        return AuthorizationHTTPResponse(status: Int(response.status.code),
            headers: response.headers.map { ($0.name, $0.value) }, body: Array(buffer: collected))
    }
}

// MARK: JSON

enum Documents {
    static let limits = JSONLimits.balanced

    static func object(_ bytes: [UInt8], _ subject: String) throws -> JSONObject {
        guard let value = try? WireCodec.parse(bytes, limits: limits).result, let object = value.objectValue else {
            throw OAuthClientError.invalidDocument(subject)
        }
        return object
    }

    static func write(_ members: [JSONMember]) throws -> [UInt8] {
        Array(try WireCodec.write(.object(try JSONObject(members: members)), limits: limits).result)
    }
}

extension JSONObject {
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func strings(_ key: String) -> [String]? {
        guard let array = self[key]?.arrayValue else { return nil }
        let strings = array.compactMap(\.stringValue)
        return strings.count == array.count ? strings : nil
    }
}

// MARK: Encoding

enum FormEncoding {
    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".utf8)

    /// Percent-encodes everything outside the unreserved set (RFC 3986), as
    /// `application/x-www-form-urlencoded` and query components require.
    static func escape(_ text: String) -> String {
        var result = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) { result.unicodeScalars.append(UnicodeScalar(byte)) }
            else { result += String(format: "%%%02X", byte) }
        }
        return result
    }

    static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { escape($0.0) + "=" + escape($0.1) }.joined(separator: "&")
    }
}

enum Base64URL {
    static func encode<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// A random URL-safe token with `byteCount` bytes of entropy.
    static func random(byteCount: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        return encode((0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// PKCE with `S256` (RFC 7636); `plain` is never used.
struct PKCE: Sendable {
    let verifier: String
    var challenge: String { Base64URL.encode(SHA256.hash(data: Array(verifier.utf8))) }
    static func make() -> PKCE { PKCE(verifier: Base64URL.random(byteCount: 32)) }
}

// MARK: WWW-Authenticate

/// Parses `WWW-Authenticate` values (RFC 9110 §11.6.1) and returns the parameters of the
/// first `Bearer` challenge, with lowercased names; nil when there is none.
enum BearerChallenge {
    static func parameters(_ values: [String]) -> [String: String]? {
        for value in values {
            if let parameters = parse(Array(value.unicodeScalars)) { return parameters }
        }
        return nil
    }

    private static func parse(_ text: [UnicodeScalar]) -> [String: String]? {
        var index = 0
        var scheme: String?
        var parameters: [String: String] = [:]
        func skip(_ characters: Set<UnicodeScalar>) { while index < text.count, characters.contains(text[index]) { index += 1 } }
        func token() -> String {
            var result = ""
            while index < text.count, !" \t,=\"".unicodeScalars.contains(text[index]) { result.unicodeScalars.append(text[index]); index += 1 }
            return result
        }
        while index < text.count {
            skip([" ", "\t", ","])
            let name = token()
            guard !name.isEmpty else { index += 1; continue }
            skip([" ", "\t"])
            if index < text.count, text[index] == "=" {
                index += 1
                skip([" ", "\t"])
                var value = ""
                if index < text.count, text[index] == "\"" {
                    index += 1
                    while index < text.count, text[index] != "\"" {
                        if text[index] == "\\", index + 1 < text.count { index += 1 }
                        value.unicodeScalars.append(text[index]); index += 1
                    }
                    index += 1
                } else {
                    value = token()
                    // token68 padding (`abc==`) belongs to the value.
                    while index < text.count, text[index] == "=" { value += "="; index += 1 }
                }
                if scheme?.lowercased() == "bearer", parameters[name.lowercased()] == nil { parameters[name.lowercased()] = value }
            } else {
                if scheme?.lowercased() == "bearer" { return parameters }
                scheme = name
            }
        }
        return scheme?.lowercased() == "bearer" ? parameters : nil
    }
}

// MARK: URLs

enum URLRules {
    /// Whether `url` may carry authorization traffic: `https`, or `http` to a loopback host
    /// when development loopback is allowed.
    static func isAllowed(_ url: URL, insecureLoopback: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false, url.fragment == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && insecureLoopback && isLoopback(url)
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasPrefix("127.")
    }

    static func origin(_ components: URLComponents) -> String? {
        guard let scheme = components.scheme?.lowercased(), let host = components.host else { return nil }
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(bracketed)" + (components.port.map { ":\($0)" } ?? "")
    }

    static func effectivePort(_ components: URLComponents) -> Int? {
        if let port = components.port { return port }
        switch components.scheme?.lowercased() { case "https": return 443; case "http": return 80; default: return nil }
    }
}
