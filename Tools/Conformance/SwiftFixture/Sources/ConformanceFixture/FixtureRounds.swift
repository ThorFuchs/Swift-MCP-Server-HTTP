// SPDX-License-Identifier: Apache-2.0
// Synthetic registration behavior adapted from the pinned public conformance
// everything-server and scenario sources; see PROVENANCE.md and retained LICENSE.
import JSON
import MCPProtocol
import MCPServer

enum FixtureRounds {
    static func elicitation(_ id: String, field: String, type: String = "string", message: String) throws -> InputDescriptor {
        .init(identifier: ScalarText(id), request: try FixtureJSON.parse("""
        {"method":"elicitation/create","params":{"message":"\(message)","requestedSchema":{"type":"object","properties":{"\(field)":{"type":"\(type)"}},"required":["\(field)"]}}}
        """))
    }
    static func sampling(_ id: String, message: String, tokens: Int = 50) throws -> InputDescriptor {
        .init(identifier: ScalarText(id), request: try FixtureJSON.parse("""
        {"method":"sampling/createMessage","params":{"messages":[{"role":"user","content":{"type":"text","text":"\(message)"}}],"maxTokens":\(tokens)}}
        """))
    }
    static func roots(_ id: String) throws -> InputDescriptor {
        .init(identifier: ScalarText(id), request: try FixtureJSON.parse(#"{"method":"roots/list","params":{}}"#))
    }
    /// Static, state-free providers explicitly reconstruct their expected input
    /// set. Stateful workflows use only production authenticated continuation state.
    static func basic(_ input: InputDescriptor, handler: @escaping @Sendable (RoundInvocation, RequestContext) async throws -> JSON) -> MultiRoundProvider {
        .init(version: ScalarText("fixture-v1"), inputs: [input], inputOnlyReconstruction: [input.identifier], replay: .integrityOnly) { _, round, context in
            if round.isRetry { return .complete(try await handler(round, context)) }
            return .inputRequired(.init(inputs: [input.identifier], inputOnly: true))
        }
    }
    static func tools() throws -> [ToolRegistration] {
        func tool(_ suffix: String, _ provider: MultiRoundProvider) throws -> ToolRegistration {
            .init(definition: try FixtureCatalog.definition("test_input_required_result_" + suffix), rounds: provider)
        }
        let name = try elicitation("user_name", field: "name", message: "What is your name?")
        let sample = try sampling("sample_request", message: "What is the capital of France?", tokens: 100)
        let root = try roots("roots_request")
        let confirm = try elicitation("confirm", field: "ok", type: "boolean", message: "Please confirm")
        var result = [
            try tool("elicitation", basic(name) { round, context in try await FixtureJSON.text("Hello, \(FixtureJSON.reply(round, "user_name", "name"))!", context: context) }),
            try tool("sampling", basic(sample) { round, context in try await FixtureJSON.text("Sampling result: \(round.responses["sample_request"]?.objectValue?["content"]?.objectValue?["text"]?.stringValue ?? "no response")", context: context) }),
            try tool("list_roots", basic(root) { round, context in try await FixtureJSON.text("Found \(round.responses["roots_request"]?.objectValue?["roots"]?.arrayValue?.count ?? 0) root(s)", context: context) }),
        ]
        for suffix in ["request_state", "tampered_state"] {
            let text = suffix == "request_state" ? "state-ok: requestState validated" : "integrity-ok: state verified"
            let provider = MultiRoundProvider(version: ScalarText("fixture-v1"), inputs: [confirm], replay: .integrityOnly) { _, round, context in
                if round.isRetry { return .complete(try await FixtureJSON.text(text, context: context)) }
                return .inputRequired(.init(inputs: [confirm.identifier], state: .value(.string(suffix))))
            }
            result.append(try tool(suffix, provider))
        }
        let greeting = try sampling("greeting", message: "Generate a greeting")
        let clientRoots = try roots("client_roots")
        result.append(try tool("multiple_inputs", .init(version: ScalarText("fixture-v1"), inputs: [name, greeting, clientRoots], replay: .integrityOnly) { _, round, context in
            if round.isRetry {
                let greetingText = round.responses["greeting"]?.objectValue?["content"]?.objectValue?["text"]?.stringValue ?? "Hello there!"
                let count = round.responses["client_roots"]?.objectValue?["roots"]?.arrayValue?.count ?? 0
                return .complete(try await FixtureJSON.text("Name: \(FixtureJSON.reply(round, "user_name", "name")); Greeting: \(greetingText); Roots: \(count)", context: context))
            }
            return .inputRequired(.init(inputs: [name.identifier, greeting.identifier, clientRoots.identifier], state: .value(.string("multiple-inputs"))))
        }))
        let step1 = try elicitation("step1", field: "name", message: "Step 1: What is your name?")
        let step2 = try elicitation("step2", field: "color", message: "Step 2: What is your favorite color?")
        result.append(try tool("multi_round", .init(version: ScalarText("fixture-v1"), inputs: [step1, step2], replay: .integrityOnly) { _, round, context in
            if !round.isRetry { return .inputRequired(.init(inputs: [step1.identifier], state: .value(.null))) }
            if case .value(let saved) = round.state, let userName = saved.stringValue {
                return .complete(try await FixtureJSON.text("Multi-round complete for \(userName) who likes \(FixtureJSON.reply(round, "step2", "color"))", context: context))
            }
            return .inputRequired(.init(inputs: [step2.identifier], state: .value(.string(FixtureJSON.reply(round, "step1", "name")))))
        }))
        let elicit = try elicitation("elicit_input", field: "value", message: "Elicitation input")
        let sampleInput = try sampling("sample_input", message: "Sample request")
        result.append(try tool("capabilities", .init(version: ScalarText("fixture-v1"), inputs: [elicit, sampleInput], replay: .integrityOnly) { _, round, context in
            if round.isRetry { return .complete(try await FixtureJSON.text("capabilities-ok: received inputs", context: context)) }
            var selected: [ScalarText] = []
            if let declared = context.capabilities["elicitation"]?.objectValue, declared.isEmpty || declared["form"]?.objectValue != nil { selected.append(elicit.identifier) }
            if context.capabilities["sampling"]?.objectValue != nil { selected.append(sampleInput.identifier) }
            if selected.isEmpty { return .complete(try await FixtureJSON.text("No supported capabilities declared", context: context)) }
            return .inputRequired(.init(inputs: selected, state: .value(.string("capabilities-test"))))
        }))
        return result
    }
    static func prompt() throws -> PromptProvider {
        let input = try elicitation("user_context", field: "context", message: "What context should the prompt use?")
        return .init(definition: try FixtureJSON.parse(#"{"name":"test_input_required_result_prompt","description":"MRTR: prompt that requires elicitation input"}"#), rounds: basic(input) { round, context in
            try await FixtureCatalog.promptText("Prompt with context: " + FixtureJSON.reply(round, "user_context", "context"), context: context)
        })
    }
}
