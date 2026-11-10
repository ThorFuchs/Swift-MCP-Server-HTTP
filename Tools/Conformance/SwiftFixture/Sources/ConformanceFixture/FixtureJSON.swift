// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import MCPProtocol
import MCPServer

/// Trusted fixture declarations are bounded public JSON operations. Dynamic
/// provider encoding uses the invocation's cumulative account and actual reports.
public enum FixtureJSON {
    public static func parse(_ text: String) throws -> JSON {
        try WireCodec.parse(Array(text.utf8), limits: .balanced).result
    }
    static func encode<T: Encodable & Sendable>(_ value: T, context: RequestContext) async throws -> JSON {
        try context.checkCancellation()
        return try await context.budget.performJSON { try JSONValueEncoder(options: .init(limits: $0)).encodeWithReport(value) }
    }
    struct Text: Encodable, Sendable { let type = "text"; let text: String }
    struct ToolText: Encodable, Sendable { let resultType = "complete"; let content: [Text]; let isError: Bool? }
    static func text(_ text: String, context: RequestContext, error: Bool? = nil) async throws -> JSON {
        try await encode(ToolText(content: [.init(text: text)], isError: error), context: context)
    }
    static func tokenText(_ token: RequestID?, context: RequestContext) async throws -> String {
        guard let token else { return "0" }
        if let text = token.value.stringValue { return text }
        let bytes = try await context.budget.performJSON { try WireCodec.write(token.value, limits: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    static func string(_ value: JSONPresence<JSON>, _ field: String) throws -> String {
        guard case .value(let json) = value, let string = json.objectValue?[field]?.stringValue else { throw CoreFailure.invalidInput }
        return string
    }
    static func reply(_ round: RoundInvocation, _ input: String, _ field: String) -> String {
        round.responses[input]?.objectValue?["content"]?.objectValue?[field]?.stringValue ?? "unknown"
    }
}
