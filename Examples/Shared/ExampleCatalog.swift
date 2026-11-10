// SPDX-License-Identifier: Apache-2.0
import Foundation
import CryptoKit
import JSON
import MCPProtocol
import MCPServer

public enum ExampleCatalog {
    public static func json(_ s: String) throws -> JSON { try WireCodec.parse(Array(s.utf8), limits: .balanced).result }
    public static func make(extensions: Bool = false) async throws -> Server {
        struct Input: Decodable, Sendable { let text: String }
        struct Output: Encodable, Sendable { let text: String }
        let echo = ToolRegistration.typed(definition: try json(#"{"name":"echo","description":"Return the supplied text","inputSchema":{"type":"object","properties":{"text":{"type":"string","maxLength":131072}},"required":["text"]},"outputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}}"#), input: Input.self) { input, context in
            try context.checkCancellation(); return Output(text: input.text)
        }
        let wait = ToolRegistration(definition: try json(#"{"name":"wait","description":"Cooperatively wait for cancellation","inputSchema":{"type":"object"}}"#)) { _, context in
            FileHandle.standardError.write(Data("EXAMPLE_PROVIDER_WAITING\n".utf8))
            while true { try context.checkCancellation(); try await Task.sleep(for: .milliseconds(10)) }
        }
        let progress = ToolRegistration(definition: try json(#"{"name":"progress","description":"Report one exact progress value","inputSchema":{"type":"object"}}"#)) { _, context in
            _ = try await context.progress(JSONNumber(parsing: "0.25"), total: JSONNumber(integer: 1))
            return try json(#"{"resultType":"complete","content":[]}"#)
        }
        let resource = ResourceProvider(definition: try json(#"{"name":"greeting","uri":"demo://greeting"}"#)) { _, _ in
            try json(#"{"resultType":"complete","contents":[{"uri":"demo://greeting","text":"Hello"}]}"#)
        }
        let prompt = PromptProvider(definition: try json(#"{"name":"greet"}"#)) { _, _ in
            try json(#"{"resultType":"complete","messages":[{"role":"user","content":{"type":"text","text":"Hello"}}]}"#)
        }
        var registrations: [ExtensionRegistration] = []
        if extensions {
            registrations.append(try .init(identifier: ScalarText("com.example/demo"), settingsSchema: json(#"{"type":"object"}"#),
                requests: [.init(method: ScalarText("com.example/demo/echo"), parametersSchema: json(#"{"type":"object","properties":{"text":{"type":"string"},"nested":{"type":"object","properties":{"number":{"type":"integer","x-mcp-header":"Number"}},"required":["number"]}},"required":["text"]}"#), resultTypes: [ScalarText("com.example/demo/echoed")]) { input, context in
                    guard case .value(let value) = input else { throw CoreFailure.invalidInput }
                    struct Reply: Encodable { let resultType = "com.example/demo/echoed"; let text: String }
                    guard let text = value.objectValue?["text"]?.stringValue else { throw CoreFailure.invalidInput }
                    return try await context.budget.performJSON { limits in
                        try JSONValueEncoder(options: .init(limits: limits)).encodeWithReport(Reply(text: text))
                    }
                }], results: [.init(type: ScalarText("com.example/demo/echoed"), schema: json(#"{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]}"#))]))
        }
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return try await Server.make(info: json(#"{"name":"swift-mcp-example","version":"source-preview"}"#),
            catalog: ServerCatalog(tools: [echo,wait,progress], resources: [resource], prompts: [prompt], completion: CompletionProvider { _, _ in try .init(values: ["hello"]) }, extensions: registrations),
            cursors: CursorProtector(keys: [.init(identifier: ScalarText("process"), material: key)], active: ScalarText("process"), clock: { Int64(Date().timeIntervalSince1970 * 1000) }),
            configuration: ServerConfiguration(activeRequests: 4, queuedRequests: 8, requestsPerPrincipal: 4, terminalWork: 900000, catalogEntries: 100, pageEntries: 25, deadlineMilliseconds: 60000, bufferedBytes: 33554432),
            middleware: [.init { view, next in try view.context.checkCancellation(); return try await next.proceed(for: view) }])
    }
}
