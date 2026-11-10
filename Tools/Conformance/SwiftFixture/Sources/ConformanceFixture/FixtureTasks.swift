// SPDX-License-Identifier: Apache-2.0
// Synthetic Tasks-extension registrations required by the pinned conformance
// scenarios (src/scenarios/server/tasks); see PROVENANCE.md and retained LICENSE.
import Foundation
import JSON
import MCPProtocol
import MCPServer
import MCPTasks

public enum FixtureTasks {
    /// One runtime per fixture process; `FixtureMain` runs it as a service.
    public static let runtime = TaskRuntime(configuration: .init(maximumTasks: 512, maximumTasksPerPrincipal: 256,
        timeToLive: .seconds(600), pollInterval: .milliseconds(100)))

    static func text(_ value: String) throws -> JSON {
        let quoted = String(decoding: try WireCodec.write(.string(value), limits: .balanced).result, as: UTF8.self)
        return try FixtureJSON.parse("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\(quoted)}]}")
    }
    static func elicitation(_ message: String, field: String, type: String) throws -> JSON {
        try FixtureJSON.parse("""
        {"method":"elicitation/create","params":{"message":"\(message)","requestedSchema":{"type":"object","properties":{"\(field)":{"type":"\(type)"}},"required":["\(field)"]}}}
        """)
    }
    static func arguments(_ input: JSONPresence<JSON>) -> JSONObject? {
        if case .value(let value) = input { return value.objectValue } else { return nil }
    }

    static func tools() throws -> [ToolRegistration] {
        let runtime = runtime
        let greet = ToolRegistration(definition: try FixtureCatalog.definition("greet",
            schema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#)) { input, context in
            try context.checkCancellation()
            return try text("Hello, \(arguments(input)?["name"]?.stringValue ?? "")!")
        }
        // Task-supporting: sync for non-declaring clients, a task otherwise.
        let slow = runtime.tool(definition: try FixtureCatalog.definition("slow_compute",
            schema: #"{"type":"object","properties":{"seconds":{"type":"number","minimum":0},"label":{"type":"string"}}}"#), mode: .optional) { input, _ in
            let seconds = (try? arguments(input)?["seconds"]?.numberValue?.integer(as: Int.self, limits: .balanced)) ?? 0
            if seconds > 0 { try await Task.sleep(for: .seconds(min(seconds, 300))) }
            return try text("Computed \(arguments(input)?["label"]?.stringValue ?? "result") after \(seconds)s")
        }
        // Task-required: always a tool execution error (completed, isError) after about one second.
        let failing = runtime.tool(definition: try FixtureCatalog.definition("failing_job"), mode: .required) { _, _ in
            try await Task.sleep(for: .seconds(1))
            return try FixtureJSON.parse(#"{"resultType":"complete","isError":true,"content":[{"type":"text","text":"Job failed"}]}"#)
        }
        // Task-supporting: a JSON-RPC (protocol) error, so the task ends as failed.
        let protocolError = runtime.tool(definition: try FixtureCatalog.definition("protocol_error_job"), mode: .optional) { _, _ in
            throw TaskFailure(code: -32603, message: "Internal error in protocol_error_job")
        }
        let confirm = runtime.tool(definition: try FixtureCatalog.definition("confirm_delete",
            schema: #"{"type":"object","properties":{"filename":{"type":"string"}}}"#), mode: .optional) { input, task in
            let file = arguments(input)?["filename"]?.stringValue ?? "file"
            let answer = try await task.requestInput(try elicitation("Delete \(file)?", field: "confirm", type: "boolean"))
            let accepted = answer.objectValue?["action"]?.stringValue == "accept"
            return try text(accepted ? "Deleted \(file)" : "Kept \(file)")
        }
        let multi = runtime.tool(definition: try FixtureCatalog.definition("multi_input"), mode: .optional) { _, task in
            async let first = task.requestInput(try elicitation("First value?", field: "first", type: "string"))
            async let second = task.requestInput(try elicitation("Second value?", field: "second", type: "string"))
            let answers = try await [first, second].map { $0.objectValue?["action"]?.stringValue ?? "none" }
            return try text("Received \(answers.joined(separator: ", "))")
        }
        // MRTR → task: round 1 asks for user_name, the final round escalates to a task.
        let name = try FixtureRounds.elicitation("user_name", field: "name", message: "What is your name?")
        let composition = ToolRegistration(definition: try FixtureCatalog.definition("test_tool_with_task"),
            rounds: .init(version: ScalarText("fixture-tasks-v1"), inputs: [name], replay: .integrityOnly) { input, round, context in
                guard let reply = round.responses["user_name"] else { return .inputRequired(.init(inputs: [name.identifier], state: .null)) }
                let user = reply.objectValue?["content"]?.objectValue?["name"]?.stringValue ?? "unknown"
                return .supplemental(try await runtime.start(input, context: context) { _, _ in try text("Hello, \(user)!") })
            })
        return [greet, slow, failing, protocolError, confirm, multi, composition]
    }
}
