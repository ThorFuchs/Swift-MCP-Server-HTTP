// SPDX-License-Identifier: Apache-2.0
// Client conformance fixture: the official referee starts `SwiftConformanceClient <server-url>`
// with the scenario in MCP_CONFORMANCE_SCENARIO and optional MCP_CONFORMANCE_CONTEXT (JSON).
import Foundation
import JSON
import MCPClient
import MCPHTTPClient
import MCPProtocol

@main
struct ConformanceClient {
    static func main() async {
        let environment = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count >= 2, let endpoint = URL(string: CommandLine.arguments.last!),
              let scenario = environment["MCP_CONFORMANCE_SCENARIO"] else {
            FileHandle.standardError.write(Data("usage: MCP_CONFORMANCE_SCENARIO=<scenario> SwiftConformanceClient <server-url>\n".utf8))
            exit(2)
        }
        do {
            let context = try environment["MCP_CONFORMANCE_CONTEXT"].map { try parse($0) }
            let client = Client(transport: HTTPClientTransport(endpoint: endpoint, timeout: .seconds(60)), configuration: .init(
                info: try parse(#"{"name":"swift-conformance-client","version":"0.1.0"}"#),
                elicitation: .init { _ in try parse(#"{"action":"accept","content":{"confirmed":true}}"#) },
                sampling: { _ in try parse(#"{"role":"assistant","content":{"type":"text","text":"ok"},"model":"conformance"}"#) },
                roots: { _ in try parse(#"{"roots":[]}"#) }))
            try await run(scenario, client: client, context: context)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(scenario): \(error)\n".utf8))
            exit(1)
        }
    }

    static func parse(_ text: String) throws -> JSON { try WireCodec.parse(Array(text.utf8), limits: .balanced).result }

    static func run(_ scenario: String, client: Client, context: JSON?) async throws {
        switch scenario {
        case "tools_call", "tools-call", "initialize":
            let tools = try await client.listTools()
            if let tool = tools.items.first { _ = try await client.callTool(tool.name, arguments: try parse(#"{"a":2,"b":3}"#)) }
        case "json-schema-ref-no-deref":
            _ = try await client.listTools()
        case "json-schema-2020-12-preservation":
            // Round-trips the focal tool's inputSchema exactly as received.
            let tools = try await client.listTools()
            guard let focal = tools.items.first(where: { $0.name == "json_schema_2020_12_tool" }) else { throw ClientError.invalidResponse("focal tool missing") }
            let arguments = JSON.object(try JSONObject(members: [JSONMember("schema", value: focal.inputSchema)]))
            _ = try await client.callTool("json_schema_echo", arguments: arguments)
        case "request-metadata":
            _ = try await client.discover()
            _ = try await client.listTools()
        case "sep-2322-client-request-state":
            _ = try await client.listTools()
            for name in ["test_mrtr_echo_state", "test_mrtr_unrelated", "test_mrtr_no_state", "test_mrtr_no_result_type"] {
                _ = try await client.callTool(name, arguments: try parse("{}"))
            }
        case "http-standard-headers":
            // Exercises every method that carries Mcp-Method (and Mcp-Name where defined).
            let tools = try await client.listTools()
            if let tool = tools.items.first { _ = try? await client.callTool(tool.name, arguments: try parse("{}")) }
            if let resources = try? await client.listResources(), let resource = resources.items.first { _ = try? await client.readResource(resource.uri) }
            if let prompts = try? await client.listPrompts(), let prompt = prompts.items.first { _ = try? await client.getPrompt(prompt.name) }
        case "http-custom-headers":
            _ = try await client.listTools()
            for call in context?.objectValue?["toolCalls"]?.arrayValue ?? [] {
                guard let name = call.objectValue?["name"]?.stringValue else { continue }
                _ = try await client.callTool(name, arguments: call.objectValue?["arguments"])
            }
        case "http-invalid-tool-headers":
            // Invalid tools are excluded by listTools; every remaining tool is called.
            for tool in try await client.listTools().items { _ = try? await client.callTool(tool.name, arguments: try parse("{}")) }
        default:
            throw ClientError.invalidResponse("unsupported scenario \(scenario)")
        }
    }
}
