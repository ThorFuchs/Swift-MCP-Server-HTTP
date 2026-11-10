// SPDX-License-Identifier: Apache-2.0
import Foundation
import JSON
import Testing
import MCPProtocol
import MCPServer
import ConformanceFixture

@Test func syntheticMutationsReplaceEachDynamicEntryOnce() async throws {
    let fixture = try await FixtureRuntime.make()
    let principal = VerifiedPrincipal(subject: ScalarText("mutation-test"), issuer: ScalarText("fixture"), resource: ScalarText("mcp"), scopes: [])
    let before = await fixture.server.activity.generation
    for (index, name) in ["test_trigger_tool_change", "test_trigger_tool_change", "test_trigger_prompt_change", "test_trigger_prompt_change"].enumerated() {
        let data = Data("""
        {"jsonrpc":"2.0","id":\(index + 1),"method":"tools/call","params":{"name":"\(name)","arguments":{},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
        """.utf8)
        let response = try await fixture.server.handle(data, principal: principal, origin: ScalarText("test"))
        let value = try WireCodec.parse(Array(try #require(response)), limits: .balanced).result
        #expect(value.objectValue?["result"] != nil)
        #expect(await fixture.server.activity.generation == before + (index < 2 ? 1 : 2))
    }
    let activity = await fixture.server.activity
    #expect(activity.active == 0 && activity.requests == 0 && activity.leases == 0)
    await fixture.clear()
}
