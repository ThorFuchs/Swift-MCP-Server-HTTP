// SPDX-License-Identifier: Apache-2.0
// Client conformance fixture: the official referee starts `SwiftConformanceClient <server-url>`
// with the scenario in MCP_CONFORMANCE_SCENARIO and optional MCP_CONFORMANCE_CONTEXT (JSON).
import Foundation
import AsyncHTTPClient
import JSON
import MCPClient
import MCPClientAuthorization
import MCPHTTPClient
import MCPProtocol
import MCPSkillsClient

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
            if scenario.hasPrefix("auth/") {
                try await authorize(endpoint: endpoint, context: context)
                exit(0)
            }
            let client = Client(transport: HTTPClientTransport(endpoint: endpoint, timeout: .seconds(60)), configuration: .init(
                info: try parse(#"{"name":"swift-conformance-client","version":"0.1.0"}"#),
                elicitation: .init { _ in
                    .accept(content: try JSONObject(members: [
                        JSONMember("confirmed", value: .boolean(true))
                    ]))
                },
                sampling: { _ in
                    try SamplingResponse.text("ok", model: "conformance", stopReason: nil)
                },
                roots: { [] }))
            try await run(scenario, client: client, context: context)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("\(scenario): \(error)\n".utf8))
            exit(1)
        }
    }

    /// Authorization scenarios: list tools and call the first one; the transport runs the
    /// OAuth flow on the first 401.
    static func authorize(endpoint: URL, context: JSON?) async throws {
        let values = context?.objectValue
        var preRegistered: [PreRegisteredClient] = []
        if let id = values?["client_id"]?.stringValue, let issuer = values?["issuer"]?.stringValue {
            preRegistered.append(PreRegisteredClient(issuer: issuer, clientID: id, clientSecret: values?["client_secret"]?.stringValue))
        }
        let configuration = OAuthClientConfiguration(
            identity: ClientIdentity(preRegistered: preRegistered,
                metadataDocument: URL(string: "https://conformance-test.local/client-metadata.json"),
                dynamicRegistration: DynamicRegistration(clientName: "swift-conformance-client")),
            redirectURI: URL(string: "http://127.0.0.1:8976/callback")!, allowsInsecureLoopback: true)
        let browser = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init(redirectConfiguration: .disallow))
        do {
            let oauth = OAuthClient(endpoint: endpoint, configuration: configuration, userAgent: RedirectCapture(client: browser))
            let client = Client(transport: HTTPClientTransport(endpoint: endpoint, timeout: .seconds(60), authorization: oauth),
                configuration: .init(info: try parse(#"{"name":"swift-conformance-client","version":"0.1.0"}"#)))
            let tools = try await client.listTools()
            if let tool = tools.items.first { _ = try await client.callTool(tool.name, arguments: try parse("{}")) }
        } catch {
            try? await browser.shutdown()
            throw error
        }
        try await browser.shutdown()
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
        case "sep-2640-client-no-prefetch":
            // A host lists skills; nothing is fetched until a skill is loaded.
            _ = try await SkillsClient(client: client).list()
        case "sep-2640-client-verify-digest", "sep-2640-client-verify-size", "sep-2640-client-verify-frontmatter":
            // Load the skill, then its other files only if SKILL.md verified.
            let skills = SkillsClient(client: client)
            for entry in try await skills.list().items {
                guard let loaded = try? await skills.load(entry) else { continue }
                for file in entry.files where file.uri != entry.uri { _ = try await skills.file(file.uri, of: loaded) }
            }
        default:
            throw ClientError.invalidResponse("unsupported scenario \(scenario)")
        }
    }
}

/// The referee's authorization endpoint answers at once with a redirect carrying the code;
/// a real host would open a browser here.
struct RedirectCapture: AuthorizationUserAgent {
    let client: HTTPClient
    func authorize(_ request: AuthorizationRequest) async throws -> URL {
        let response = try await client.execute(HTTPClientRequest(url: request.url.absoluteString), timeout: .seconds(30))
        _ = try? await response.body.collect(upTo: 64 * 1024)
        guard (300..<400).contains(Int(response.status.code)), let location = response.headers.first(name: "Location"),
              let url = URL(string: location) else { throw ClientError.invalidResponse("authorization endpoint did not redirect") }
        return url
    }
}
