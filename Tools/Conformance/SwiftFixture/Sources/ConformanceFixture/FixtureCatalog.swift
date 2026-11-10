// SPDX-License-Identifier: Apache-2.0
// Adapted synthetic registrations: pinned conformance everything-server/scenarios.
// Their full mixed upstream license and source identities are retained; see PROVENANCE.md.
import Foundation
import JSON
import MCPProtocol
import MCPServer

enum FixtureCatalog {
    static let image = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFBQIAX8jx0gAAAABJRU5ErkJggg=="
    static let audio = "UklGRiYAAABXQVZFZm10IBAAAAABAAEAQB8AAAB9AAACABAAZGF0YQIAAAA="
    static func definition(_ name: String, schema: String = #"{"type":"object","properties":{}}"#) throws -> JSON {
        try FixtureJSON.parse("{\"name\":\"\(name)\",\"description\":\"Synthetic conformance fixture\",\"inputSchema\":\(schema)}")
    }
    static func constant(_ name: String, _ content: String) throws -> ToolRegistration {
        let response = try FixtureJSON.parse("{\"resultType\":\"complete\",\"content\":\(content)}")
        return .init(definition: try definition(name)) { _, context in try context.checkCancellation(); return response }
    }
    static func make(events: FixtureEvents, dynamicTools: Bool = false, dynamicPrompts: Bool = false) throws -> ServerCatalog {
        var tools = [
            // Callable no-argument sentinel for generic header probes. Keeping
            // the conditional 2020-12 tool fully strict avoids a schema error
            // falsely masquerading as header rejection.
            try constant("a_no_arguments", #" [{"type":"text","text":"Fixture header probe"}] "#),
            try constant("test_simple_text", #"[{"type":"text","text":"This is a simple text response for testing."}]"#),
            try constant("test_image_content", "[{\"type\":\"image\",\"data\":\"\(image)\",\"mimeType\":\"image/png\"}]"),
            try constant("test_audio_content", "[{\"type\":\"audio\",\"data\":\"\(audio)\",\"mimeType\":\"audio/wav\"}]"),
            try constant("test_embedded_resource", #"[{"type":"resource","resource":{"uri":"test://embedded-resource","mimeType":"text/plain","text":"This is an embedded resource content."}}]"#),
            try constant("test_multiple_content_types", #"""
            [{"type":"text","text":"Multiple content types test:"},{"type":"image","data":"\#(image)","mimeType":"image/png"},{"type":"resource","resource":{"uri":"test://mixed-content-resource","mimeType":"application/json","text":"{\"test\":\"data\",\"value\":123}"}}]
            """#),
        ]
        tools.append(.init(definition: try definition("test_error_handling")) { _, context in
            try await FixtureJSON.text("This tool intentionally returns an error for testing", context: context, error: true)
        })
        tools.append(.init(definition: try definition("test_missing_capability"), requiredFeatures: [.sampling]) { _, context in
            try await FixtureJSON.text("Sampling supported", context: context)
        })
        for name in ["test_tool_with_progress", "test_streaming_elicitation"] {
            tools.append(.init(definition: try definition(name)) { _, context in
                if context.progressToken != nil {
                    for value in [0, 50, 100] {
                        if value > 0 { try await Task.sleep(for: .milliseconds(60)) }
                        try await context.progress(JSONNumber(integer: value), total: JSONNumber(integer: 100), message: "Completed step \(value) of 100")
                    }
                }
                let text = name == "test_tool_with_progress" ? try await FixtureJSON.tokenText(context.progressToken, context: context) : "Streaming complete"
                return try await FixtureJSON.text(text, context: context)
            })
        }
        for name in ["test_tool_with_logging", "test_logging_tool"] {
            tools.append(.init(definition: try definition(name)) { _, context in
                for text in ["Tool execution started", "Tool processing data", "Tool execution completed"] {
                    _ = try await context.log(.info, data: .string(text))
                    try await Task.sleep(for: .milliseconds(60))
                }
                return try await FixtureJSON.text(name == "test_logging_tool" ? "Logging evaluated" : "Tool with logging executed successfully", context: context)
            })
        }
        for (name, event) in [("test_trigger_tool_change", SubscriptionEvent.toolsChanged), ("test_trigger_prompt_change", .promptsChanged)] {
            tools.append(.init(definition: try definition(name)) { _, context in
                try await events.mutate(event)
                return try await FixtureJSON.text("Mutation triggered", context: context)
            })
        }
        tools.append(.init(definition: try definition("test_custom_header", schema: #"{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"}},"required":["region"]}"#)) { value, context in
            try await FixtureJSON.text(FixtureJSON.string(value, "region"), context: context)
        })
        // Exact raw 2020-12 declaration from the pinned public everything-server;
        // validation remains the production private Swift-JSON schema adapter.
        let schema = ##"{"$schema":"https://json-schema.org/draft/2020-12/schema","type":"object","$defs":{"address":{"$anchor":"addressDef","type":"object","properties":{"street":{"type":"string"},"city":{"type":"string"}}}},"properties":{"name":{"type":"string"},"address":{"$ref":"#/$defs/address"},"contactMethod":{"type":"string","enum":["phone","email"]},"phone":{"type":"string"},"email":{"type":"string"}},"allOf":[{"anyOf":[{"required":["phone"]},{"required":["email"]}]}],"if":{"properties":{"contactMethod":{"const":"phone"}},"required":["contactMethod"]},"then":{"required":["phone"]},"else":{"required":["email"]},"additionalProperties":false}"##
        tools.append(.init(definition: try definition("json_schema_2020_12_tool", schema: schema)) { value, context in
            guard case .value(let arguments) = value else { throw CoreFailure.invalidInput }
            let bytes = try await context.budget.performJSON { try WireCodec.write(arguments, limits: $0) }
            return try await FixtureJSON.text("JSON Schema 2020-12 tool called with: " + String(decoding: bytes, as: UTF8.self), context: context)
        })
        tools += try FixtureRounds.tools()
        if dynamicTools { tools.append(try constant("test_dynamic_tool", #" [{"type":"text","text":"Dynamic tool"}] "#)) }
        var prompts = try promptProviders()
        prompts.append(try FixtureRounds.prompt())
        if dynamicPrompts { prompts.append(.init(definition: try FixtureJSON.parse(#"{"name":"test_dynamic_prompt","description":"Dynamic synthetic prompt"}"#)) { _, context in try await promptText("Dynamic prompt", context: context) }) }
        return try .init(tools: tools, resources: resources(), templates: [template()], prompts: prompts,
            completion: .init { _, _ in try .init(values: [], total: 0) }, cache: CacheHints(ttlMilliseconds: 300000, scope: .public),
            listChanged: [.listTools, .listPrompts])
    }
    struct ResourceText: Encodable, Sendable { let uri: String; let mimeType: String; let text: String }
    struct ResourceResult: Encodable, Sendable { let resultType = "complete"; let contents: [ResourceText]; let ttlMs = 300000; let cacheScope = "private" }
    static func resources() throws -> [ResourceProvider] {
        var resources: [ResourceProvider] = []
        for (uri, name, text) in [
            ("test://static-text", "static-text", "This is the content of the static text resource."),
            ("test://watched-resource", "watched-resource", "Watched resource content"),
            ("test://stateless-static-text", "Stateless Static Text", "Static text content from the stateless draft path.")
        ] {
            resources.append(.init(definition: try FixtureJSON.parse("{\"uri\":\"\(uri)\",\"name\":\"\(name)\",\"mimeType\":\"text/plain\"}")) { _, context in
                try await FixtureJSON.encode(ResourceResult(contents: [.init(uri: uri, mimeType: "text/plain", text: text)]), context: context)
            })
        }
        let binary = try FixtureJSON.parse("{\"resultType\":\"complete\",\"ttlMs\":300000,\"cacheScope\":\"private\",\"contents\":[{\"uri\":\"test://static-binary\",\"mimeType\":\"image/png\",\"blob\":\"\(image)\"}]}")
        resources.append(.init(definition: try FixtureJSON.parse(#"{"uri":"test://static-binary","name":"static-binary","mimeType":"image/png"}"#)) { _, context in try context.checkCancellation(); return binary })
        return resources
    }
    struct TemplateData: Encodable, Sendable { let id: String; let templateTest = true; let data: String }
    static func template() throws -> ResourceTemplateProvider {
        .init(definition: try FixtureJSON.parse(#"{"name":"template","uriTemplate":"test://template/{id}/data","mimeType":"application/json"}"#), matches: { uri, _ in
            uri.hasPrefix("test://template/") && uri.hasSuffix("/data") && uri.dropFirst("test://template/".count).dropLast(5).allSatisfy { $0 != "/" }
        }) { value, context in
            guard case .value(let raw) = value, let uri = raw.stringValue, uri.utf8.count <= 4096 else { throw CoreFailure.invalidInput }
            let segment = String(uri.dropFirst("test://template/".count).dropLast("/data".count))
            let id = segment.removingPercentEncoding ?? segment
            let data = try await FixtureJSON.encode(TemplateData(id: id, data: "Data for ID: " + id), context: context)
            let bytes = try await context.budget.performJSON { try WireCodec.write(data, limits: $0) }
            return try await FixtureJSON.encode(ResourceResult(contents: [.init(uri: uri, mimeType: "application/json", text: String(decoding: bytes, as: UTF8.self))]), context: context)
        }
    }
    struct Message: Encodable, Sendable { let role = "user"; let content: FixtureJSON.Text }
    struct PromptResult: Encodable, Sendable { let resultType = "complete"; let messages: [Message] }
    static func promptText(_ text: String, context: RequestContext) async throws -> JSON {
        try await FixtureJSON.encode(PromptResult(messages: [.init(content: .init(text: text))]), context: context)
    }
    static func promptProviders() throws -> [PromptProvider] {
        let imagePrompt = try FixtureJSON.parse("{\"resultType\":\"complete\",\"messages\":[{\"role\":\"user\",\"content\":{\"type\":\"image\",\"data\":\"\(image)\",\"mimeType\":\"image/png\"}},{\"role\":\"user\",\"content\":{\"type\":\"text\",\"text\":\"Please analyze the image above.\"}}]}")
        return [
            .init(definition: try FixtureJSON.parse(#"{"name":"test_simple_prompt","title":"Simple Test Prompt","description":"A simple prompt without arguments"}"#)) { _, context in try await promptText("This is a simple prompt for testing.", context: context) },
            .init(definition: try FixtureJSON.parse(#"{"name":"test_prompt_with_arguments","title":"Prompt With Arguments","description":"A prompt with required arguments","arguments":[{"name":"arg1","required":true},{"name":"arg2","required":true}]}"#)) { value, context in
                try await promptText("Prompt with arguments: arg1='\(FixtureJSON.string(value, "arg1"))', arg2='\(FixtureJSON.string(value, "arg2"))'", context: context)
            },
            .init(definition: try FixtureJSON.parse(#"{"name":"test_prompt_with_embedded_resource","description":"A prompt that includes an embedded resource","arguments":[{"name":"resourceUri","required":true}]}"#)) { value, context in
                struct Resource: Encodable, Sendable { let uri: String; let mimeType = "text/plain"; let text = "Embedded resource content for testing." }
                struct Content: Encodable, Sendable { let type = "resource"; let resource: Resource }
                struct EmbeddedMessage: Encodable, Sendable { let role = "user"; let content: Content }
                struct Result: Encodable, Sendable { let resultType = "complete"; let messages: [JSON] }
                let embedded = try await FixtureJSON.encode(EmbeddedMessage(content: .init(resource: .init(uri: FixtureJSON.string(value, "resourceUri")))), context: context)
                let text = try await FixtureJSON.encode(Message(content: .init(text: "Please process the embedded resource above.")), context: context)
                return try await FixtureJSON.encode(Result(messages: [embedded, text]), context: context)
            },
            .init(definition: try FixtureJSON.parse(#"{"name":"test_prompt_with_image","description":"A prompt that includes image content"}"#)) { _, context in try context.checkCancellation(); return imagePrompt },
        ]
    }
}
