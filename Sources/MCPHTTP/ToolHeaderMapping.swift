// SPDX-License-Identifier: Apache-2.0
import JSON
import MCPProtocol
import MCPServer

/// Request mapping over a validated generation's properties-only paths. Unknown
/// headers stay unknown. Null/absent values have no mirror; defaults are not applied.
public struct ToolHeaderMapping: Sendable {
    public let declarations: [HeaderDeclaration]
    public init(_ declarations: [HeaderDeclaration]) throws {
        guard declarations.count <= 64 else { throw HeaderFailure.tooLarge }
        var names = Set<ScalarText>()
        for declaration in declarations {
            guard !declaration.path.isEmpty, declaration.path.count <= 32,
                  declaration.path.allSatisfy({ $0.description.utf8.count <= 4096 }),
                  declaration.name.hasPrefix("Mcp-Param-"), declaration.name.utf8.count <= 266,
                  HeaderFields.validName(declaration.name) else { throw HeaderFailure.invalidName }
            let key = ScalarText(String(decoding: declaration.name.utf8.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self))
            guard names.insert(key).inserted else { throw HeaderFailure.duplicate }
        }
        self.declarations = declarations
    }
    public func validate(arguments: JSON, headers: HeaderFields, budget: RequestBudget) async throws {
        do {
            for declaration in declarations {
                try Task.checkCancellation()
                // Header storage is bounded at construction; charge each search.
                try await budget.consume(UInt64(headers.logicalBytes * 2 + declaration.name.utf8.count))
                let raw = try headers.uniqueValue(declaration.name)
                var selected: JSON? = arguments
                for key in declaration.path {
                    guard let object = selected?.objectValue else { selected = nil; break }
                    for member in object {
                        try await budget.consume(UInt64(member.key.string.utf8.count + key.description.utf8.count + 1))
                    }
                    selected = object[key.description]
                }
                guard let value = selected, !value.isNull else {
                    if raw != nil { throw HeaderFailure.mismatch }; continue
                }
                guard let raw else { throw HeaderFailure.missing }
                try await budget.consume(UInt64(raw.utf8.count))
                let decoded = try HeaderMirror.decode(raw)
                switch declaration.primitive {
                case .string:
                    guard let body = value.stringValue else { throw HeaderFailure.mismatch }
                    try await budget.consume(UInt64(body.utf8.count + decoded.utf8.count))
                    guard body.utf8.elementsEqual(decoded.utf8) else { throw HeaderFailure.mismatch }
                case .boolean:
                    guard let body = value.booleanValue,
                          decoded.utf8.elementsEqual((body ? "true" : "false").utf8) else { throw HeaderFailure.mismatch }
                case .integer:
                    let parsed: JSON
                    do {
                        var limits = JSONLimits.conservative; limits[.inputBytes] = 16_384
                        parsed = try await budget.performJSON(limits: limits) { try JSONParser(options: .init(limits: $0)).parseWithReport(Array(decoded.utf8)) }
                    } catch let error as JSONFailure where error.category == .syntax { throw HeaderFailure.invalidValue }
                    guard let body = value.numberValue, body.isInteger, let other = parsed.numberValue, other.isInteger else { throw HeaderFailure.mismatch }
                    let pair: [Int64]
                    do {
                        let first = try await budget.performUnreported(workUnits: 4096) { try body.integer(as: Int64.self, limits: $0) }
                        let second = try await budget.performUnreported(workUnits: 4096) { try other.integer(as: Int64.self, limits: $0) }
                        pair = [first, second]
                    } catch let error as JSONFailure where error.category == .conversion { throw HeaderFailure.mismatch }
                    guard pair.allSatisfy({ (-9_007_199_254_740_991...9_007_199_254_740_991).contains($0) }), pair[0] == pair[1] else { throw HeaderFailure.mismatch }
                }
            }
        } catch { await budget.terminate(); throw error }
    }
}
