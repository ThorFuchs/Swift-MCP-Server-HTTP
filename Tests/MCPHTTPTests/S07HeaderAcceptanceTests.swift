// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP

private func s07HeaderJSON(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
private func s07HeaderRequest(_ arguments: String) -> Data {
    Data((#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"header","arguments":"# + arguments +
        #", "_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#).utf8)
}
private let s07HeaderPrincipal = VerifiedPrincipal(subject: ScalarText("header-reader"), issuer: ScalarText("host"), resource: ScalarText("sdk"), scopes: [])
private final class S07HeaderTrace: Sendable {
    private let values = Mutex([String]())
    func append(_ value: String) { values.withLock { $0.append(value) } }
    var snapshot: [String] { values.withLock { $0 } }
}
private func s07HeaderServer(_ tool: ToolRegistration) async throws -> Server {
    try await Server.make(info: s07HeaderJSON(#"{"name":"s07-header","version":"1"}"#), catalog: ServerCatalog(tools: [tool]),
        cursors: CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 4, count: 32))], active: ScalarText("test"), clock: { 1000 }))
}
private func s07Mirror(_ headers: HeaderFields, order: S07HeaderTrace) -> RequestMirrorValidator {
    { declarations, input, budget in
        order.append("mirror:" + declarations.map(\.name).sorted().joined(separator: ","))
        guard case .value(let arguments) = input else { throw RequestMirrorFailure.mismatch }
        do { try await ToolHeaderMapping(declarations).validate(arguments: arguments, headers: headers, budget: budget) }
        catch let failure as HeaderFailure where failure == .mismatch || failure == .missing || failure == .invalidValue || failure == .duplicate {
            throw RequestMirrorFailure.mismatch
        }
    }
}
private func s07HeaderResponse(_ server: Server, arguments: String, headers: HeaderFields, order: S07HeaderTrace) async throws -> JSON {
    let data = try #require(await server.handle(s07HeaderRequest(arguments), principal: s07HeaderPrincipal,
        origin: ScalarText("s07-origin"), mirror: s07Mirror(headers, order: order)))
    return try JSONParser().parseWithReport(Array(data)).result
}
private func s07Mapping(_ schema: String) async throws -> ToolHeaderMapping {
    let budget = try RequestBudget(workUnits: 64_000_000)
    let prepared = try await SchemaPreparation.prepare(s07HeaderJSON(schema), identifier: 1, budget: budget)
    let declarations = try await SchemaPreparation.headers(for: prepared, budget: budget)
    #expect(await budget.snapshot.activeReservations == 0)
    return try ToolHeaderMapping(declarations)
}
private func s07HeaderClean(_ server: Server) async {
    let activity = await server.activity
    #expect(activity.active == 0 && activity.requests == 0 && activity.leases == 0 && activity.bufferedBytes == 0)
}

// Actual core/schema/mapper calls, no HTTP listener or status-framing proof.
@Suite(.serialized) struct S07HeaderAcceptance {
    @Test func nestedThreePrimitiveHeadersAreCheckedAfterSchemaAndBeforeEffects() async throws {
        let order = S07HeaderTrace()
        let definition = try s07HeaderJSON(#"{"name":"header","inputSchema":{"type":"object","required":["nested"],"properties":{"nested":{"type":"object","required":["id","flag","text"],"properties":{"id":{"type":"integer","x-mcp-header":"ID"},"flag":{"type":"boolean","x-mcp-header":"Flag"},"text":{"type":"string","x-mcp-header":"Text"}}}}}}"#)
        let tool = ToolRegistration(definition: definition) { _, _ in
            order.append("provider")
            return try s07HeaderJSON(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await s07HeaderServer(tool)
        let valid = #"{"nested":{"id":9007199254740991,"flag":false,"text":"=?base64?literal?="}}"#
        let headers = try HeaderFields([.init("mcp-param-id", "9.007199254740991e15"), .init("Mcp-Param-Flag", "false"),
            .init("Mcp-Param-Text", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=")])
        let invalid = try await s07HeaderResponse(server, arguments: #"{"nested":{"id":1,"flag":"false","text":"x"}}"#, headers: headers, order: order)
        #expect(try invalid.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        #expect(order.snapshot.isEmpty)
        let missing = try await s07HeaderResponse(server, arguments: valid, headers: HeaderFields([]), order: order)
        #expect(try missing.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32020)
        let accepted = try await s07HeaderResponse(server, arguments: valid, headers: headers, order: order)
        #expect(accepted.objectValue?["result"] != nil)
        let mirror = "mirror:Mcp-Param-Flag,Mcp-Param-ID,Mcp-Param-Text"
        #expect(order.snapshot == [mirror, mirror, "provider"])
        await s07HeaderClean(server)
    }

    @Test func mappingFailuresAreExactAndMakeTheSharedAccountTerminal() async throws {
        let mapping = try await s07Mapping(#"{"type":"object","properties":{"n":{"type":"integer","x-mcp-header":"N"}}}"#)
        let cases: [(String, [HeaderFields.Field], HeaderFailure)] = [
            (#"{"n":42}"#, [], .missing),
            (#"{"n":42}"#, [.init("Mcp-Param-N", "41")], .mismatch),
            (#"{"n":42}"#, [.init("Mcp-Param-N", "42"), .init("mcp-param-n", "42")], .duplicate),
            (#"{"n":42}"#, [.init("Mcp-Param-N", "+42")], .invalidValue),
            (#"{"n":42}"#, [.init("Mcp-Param-N", "42.5")], .mismatch),
            (#"{"n":9007199254740992}"#, [.init("Mcp-Param-N", "9007199254740992")], .mismatch),
            (#"{"n":-9007199254740992}"#, [.init("Mcp-Param-N", "-9007199254740992")], .mismatch),
            (#"{"n":"42"}"#, [.init("Mcp-Param-N", "42")], .mismatch)
        ]
        for (body, fields, expected) in cases {
            let budget = try RequestBudget(workUnits: 8_000_000)
            let arguments = try s07HeaderJSON(body), headers = try HeaderFields(fields)
            await #expect(throws: expected) { try await mapping.validate(arguments: arguments, headers: headers, budget: budget) }
            let state = await budget.snapshot
            #expect(state.isTerminal && state.terminalTransitions == 1 && state.activeReservations == 0)
            await #expect(throws: RequestBudget.Failure.exhausted) { try await budget.consume(1) }
            #expect(await budget.snapshot.terminalTransitions == 1)
        }
        for number in ["9007199254740991", "-9007199254740991", "-0"] {
            let budget = try RequestBudget(workUnits: 8_000_000)
            try await mapping.validate(arguments: s07HeaderJSON("{\"n\":\(number)}"),
                headers: HeaderFields([.init("Mcp-Param-N", number == "-0" ? "0" : number)]), budget: budget)
            #expect(await !budget.snapshot.isTerminal)
        }
    }

    @Test func absentValuesDoNotApplyDefaultsAndNullMappingDoesNotRelaxSchema() async throws {
        let mapping = try await s07Mapping(#"{"type":"object","properties":{"nested":{"type":"object","properties":{"text":{"type":"string","default":"fallback","x-mcp-header":"Text"}}}}}"#)
        for body in ["{}", #"{"nested":{}}"#, #"{"nested":{"text":null}}"#] {
            let budget = try RequestBudget(workUnits: 8_000_000)
            try await mapping.validate(arguments: s07HeaderJSON(body), headers: HeaderFields([.init("Mcp-Param-Unknown", "ignored")]), budget: budget)
            #expect(await !budget.snapshot.isTerminal)
            await #expect(throws: HeaderFailure.mismatch) {
                try await mapping.validate(arguments: s07HeaderJSON(body), headers: HeaderFields([.init("Mcp-Param-Text", "fallback")]), budget: budget)
            }
        }
        // Mapper omission for null is not permission to use null where the
        // registered string schema forbids it. The full path validates first.
        let order = S07HeaderTrace()
        let tool = ToolRegistration(definition: try s07HeaderJSON(#"{"name":"header","inputSchema":{"type":"object","properties":{"text":{"type":"string","default":"fallback","x-mcp-header":"Text"}}}}"#)) { input, _ in
            order.append("provider")
            guard case .value(let value) = input else { throw CoreFailure.invalidInput }
            #expect(value.objectValue?["text"] == nil)
            return try s07HeaderJSON(#"{"resultType":"complete","content":[]}"#)
        }
        let server = try await s07HeaderServer(tool)
        let invalid = try await s07HeaderResponse(server, arguments: #"{"text":null}"#, headers: HeaderFields([]), order: order)
        #expect(try invalid.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        #expect(order.snapshot.isEmpty)
        #expect(try await s07HeaderResponse(server, arguments: "{}", headers: HeaderFields([]), order: order).objectValue?["result"] != nil)
        #expect(order.snapshot == ["mirror:Mcp-Param-Text", "provider"])
        await s07HeaderClean(server)
    }

    @Test func catalogReplacementMovesSchemaHeaderAndProviderTogether() async throws {
        let order = S07HeaderTrace()
        func tool(_ n: Int, header: String) throws -> ToolRegistration {
            let definition = try s07HeaderJSON("{\"name\":\"header\",\"inputSchema\":{\"type\":\"object\",\"required\":[\"n\"],\"properties\":{\"n\":{\"type\":\"integer\",\"const\":\(n),\"x-mcp-header\":\"\(header)\"}}}}")
            return ToolRegistration(definition: definition) { _, context in
                #expect(context.generation == UInt64(n))
                order.append("provider:\(n)")
                return try s07HeaderJSON(#"{"resultType":"complete","content":[]}"#)
            }
        }
        let server = try await s07HeaderServer(tool(1, header: "A"))
        #expect(try await s07HeaderResponse(server, arguments: #"{"n":1}"#, headers: HeaderFields([.init("Mcp-Param-A", "1")]), order: order).objectValue?["result"] != nil)
        try await server.replaceCatalog(ServerCatalog(tools: [tool(2, header: "B")]))
        let oldSchema = try await s07HeaderResponse(server, arguments: #"{"n":1}"#, headers: HeaderFields([.init("Mcp-Param-A", "1")]), order: order)
        #expect(try oldSchema.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
        let oldHeader = try await s07HeaderResponse(server, arguments: #"{"n":2}"#, headers: HeaderFields([.init("Mcp-Param-A", "2")]), order: order)
        #expect(try oldHeader.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32020)
        #expect(try await s07HeaderResponse(server, arguments: #"{"n":2}"#, headers: HeaderFields([.init("Mcp-Param-B", "2")]), order: order).objectValue?["result"] != nil)
        #expect(order.snapshot == ["mirror:Mcp-Param-A", "provider:1", "mirror:Mcp-Param-B", "mirror:Mcp-Param-B", "provider:2"])
        await s07HeaderClean(server)
    }
}
