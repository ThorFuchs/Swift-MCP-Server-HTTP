// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP

@Test func runtimeValidatesNestedSchemaBeforeProductionHeaderMapping() async throws {
    @Sendable func parse(_ text: String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
    let definition = try parse(#"{"name":"header","inputSchema":{"type":"object","required":["nested"],"properties":{"nested":{"type":"object","properties":{"number":{"type":"integer","x-mcp-header":"Number"}},"required":["number"]}}}}"#)
    let calls = Mutex(0), mappings = Mutex(0)
    let tool = ToolRegistration(definition: definition) { _, _ in calls.withLock { $0 += 1 }; return try parse(#"{"resultType":"complete","content":[]}"#) }
    let cursor = try CursorProtector(keys: [.init(identifier: ScalarText("test"), material: Data(repeating: 1, count: 32))], active: ScalarText("test"), clock: { 1000 })
    let server = try await Server.make(info: parse(#"{"name":"test","version":"1"}"#), catalog: ServerCatalog(tools: [tool]), cursors: cursor)
    let principal = VerifiedPrincipal(subject: ScalarText("test"), issuer: ScalarText("test"), resource: ScalarText("test"), scopes: [])
    func request(_ argument: String) -> Data { Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"header\",\"arguments\":{\"nested\":{\"number\":\(argument)}},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}".utf8) }
    let headers = try HeaderFields([.init("Mcp-Param-Number", "42")])
    let mirror: RequestMirrorValidator = { declarations, arguments, budget in
        mappings.withLock { $0 += 1 }
        #expect(declarations.count == 1 && declarations[0].path == [ScalarText("nested"), ScalarText("number")])
        guard case .value(let value) = arguments else { throw RequestMirrorFailure.mismatch }
        do { try await ToolHeaderMapping(declarations).validate(arguments: value, headers: headers, budget: budget) }
        catch let error as HeaderFailure where error == .mismatch || error == .missing || error == .invalidValue {
            throw RequestMirrorFailure.mismatch
        }
    }
    let invalid = try #require(await server.handle(request("null"), principal: principal, origin: ScalarText("origin"), mirror: mirror))
    #expect(try parse(String(decoding: invalid, as: UTF8.self)).objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32602)
    #expect(mappings.withLock { $0 } == 0 && calls.withLock { $0 } == 0)
    let mismatch = try #require(await server.handle(request("41"), principal: principal, origin: ScalarText("origin"), mirror: mirror))
    #expect(try parse(String(decoding: mismatch, as: UTF8.self)).objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32020)
    #expect(calls.withLock { $0 } == 0)
    let valid = try #require(await server.handle(request("42"), principal: principal, origin: ScalarText("origin"), mirror: mirror))
    #expect(try parse(String(decoding: valid, as: UTF8.self)).objectValue?["result"] != nil)
    #expect(mappings.withLock { $0 } == 2 && calls.withLock { $0 } == 1)
}
