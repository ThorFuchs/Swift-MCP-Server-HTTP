// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPServerTesting
import ConformanceFixture

private func json(_ text: String) throws -> JSON { try FixtureJSON.parse(text) }
private func request(_ method: String, id: Int = 1, fields: String = "", capabilities: String = #"{"elicitation":{"form":{}},"sampling":{},"roots":{}}"#) -> Data {
    Data("""
    {"jsonrpc":"2.0","id":\(id),"method":"\(method)","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":\(capabilities)}\(fields)}}
    """.utf8)
}
private let principal = VerifiedPrincipal(subject: ScalarText("native"), issuer: ScalarText("fixture"), resource: ScalarText("mcp"), scopes: [])
private func exchange(_ fixture: FixtureRuntime, _ data: Data) async throws -> JSON {
    try WireCodec.parse(Array(try await fixture.server.handle(data, principal: principal, origin: ScalarText("native"))!), limits: .balanced).result
}
private func encodedString(_ value: String) throws -> String { String(decoding: try WireCodec.write(.string(value), limits: .balanced).result, as: UTF8.self) }
private func token(_ response: JSON) throws -> String { try #require(response.objectValue?["result"]?.objectValue?["requestState"]?.stringValue) }
private func text(_ response: JSON) -> String? { response.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue }

@Suite(.serialized) struct NativeFixtureBehavior {
    @Test func realRegistrationsContentErrorsAndCacheMetadata() async throws {
        let fixture = try await FixtureRuntime.make()
        let list = try await exchange(fixture, request("tools/list"))
        let names = Set(list.objectValue?["result"]?.objectValue?["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [])
        #expect(names.contains("test_simple_text") && names.contains("test_input_required_result_multiple_inputs") && names.contains("test_trigger_tool_change"))
        #expect(!names.contains(where: { $0.hasPrefix("tasks/") }))
        #expect(list.objectValue?["result"]?.objectValue?["cacheScope"]?.stringValue == "public")
        #expect(text(try await exchange(fixture, request("tools/call", id: 2, fields: #", "name":"test_simple_text""#))) == "This is a simple text response for testing.")
        let error = try await exchange(fixture, request("tools/call", id: 3, fields: #", "name":"test_error_handling""#))
        #expect(error.objectValue?["result"]?.objectValue?["isError"]?.booleanValue == true)
        let binary = try await exchange(fixture, request("resources/read", id: 4, fields: #", "uri":"test://static-binary""#))
        let blob = try #require(binary.objectValue?["result"]?.objectValue?["contents"]?.arrayValue?.first?.objectValue?["blob"]?.stringValue)
        #expect(Data(base64Encoded: blob)?.starts(with: [137, 80, 78, 71]) == true)
        let unknown = try await exchange(fixture, request("resources/read", id: 5, fields: #", "uri":"test://absent""#))
        #expect(unknown.objectValue?["error"]?.objectValue?["data"]?.objectValue?["uri"]?.stringValue == "test://absent")
        await fixture.clear()
    }
    @Test func staticInputsIgnoreExtrasButValidateRecognizedResponses() async throws {
        let fixture = try await FixtureRuntime.make()
        let start = try await exchange(fixture, request("tools/call", fields: #", "name":"test_input_required_result_elicitation","arguments":{}"#))
        #expect(start.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue?["user_name"] != nil)
        #expect(start.objectValue?["result"]?.objectValue?["requestState"] == nil)
        let good = try await exchange(fixture, request("tools/call", id: 2, fields: #", "name":"test_input_required_result_elicitation","arguments":{},"inputResponses":{"user_name":{"action":"accept","content":{"name":"Alice"}},"extra":{"action":"accept","content":{"other":"unused"}}}"#))
        #expect(text(good) == "Hello, Alice!")
        let wrong = try await exchange(fixture, request("tools/call", id: 3, fields: #", "name":"test_input_required_result_elicitation","arguments":{},"inputResponses":{"user_name":{"action":"accept","content":{"name":false}}}"#))
        #expect(wrong.objectValue?["error"] != nil)
        await fixture.clear()
    }
    @Test func authenticatedMultiRoundAndTamperingUseProductionState() async throws {
        let fixture = try await FixtureRuntime.make()
        let first = try await exchange(fixture, request("tools/call", fields: #", "name":"test_input_required_result_multi_round","arguments":{}"#))
        let firstToken = try token(first)
        let second = try await exchange(fixture, request("tools/call", id: 2, fields: #", "name":"test_input_required_result_multi_round","arguments":{},"inputResponses":{"step1":{"action":"accept","content":{"name":"Alice"}}},"requestState":"# + encodedString(firstToken)))
        let secondToken = try token(second); #expect(firstToken != secondToken)
        let complete = try await exchange(fixture, request("tools/call", id: 3, fields: #", "name":"test_input_required_result_multi_round","arguments":{},"inputResponses":{"step2":{"action":"accept","content":{"color":"blue"}}},"requestState":"# + encodedString(secondToken)))
        #expect(text(complete) == "Multi-round complete for Alice who likes blue")
        let tampered = try await exchange(fixture, request("tools/call", id: 4, fields: #", "name":"test_input_required_result_multi_round","arguments":{},"requestState":"# + encodedString(secondToken + "X")))
        #expect(tampered.objectValue?["error"] != nil)
        await fixture.clear()
    }
    @Test func capabilitiesAndSchemaConditionsRemainAuthoritative() async throws {
        let fixture = try await FixtureRuntime.make()
        let capabilities = try await exchange(fixture, request("tools/call", fields: #", "name":"test_input_required_result_capabilities","arguments":{}"#, capabilities: #"{"sampling":{}}"#))
        let inputs = try #require(capabilities.objectValue?["result"]?.objectValue?["inputRequests"]?.objectValue)
        #expect(inputs.count == 1 && inputs["sample_input"] != nil)
        let missing = try await exchange(fixture, request("tools/call", id: 2, fields: #", "name":"test_missing_capability""#, capabilities: "{}"))
        #expect(try missing.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as: Int.self, limits: .balanced) == -32021)
        let invalid = try await exchange(fixture, request("tools/call", id: 3, fields: #", "name":"json_schema_2020_12_tool","arguments":{"contactMethod":"phone","email":"x"}"#))
        #expect(invalid.objectValue?["error"] != nil)
        let valid = try await exchange(fixture, request("tools/call", id: 4, fields: #", "name":"json_schema_2020_12_tool","arguments":{"contactMethod":"phone","phone":"x"}"#))
        #expect(valid.objectValue?["result"] != nil)
        await fixture.clear()
    }
    @Test func readinessPublicationRefusesOverwriteAndForeignBindOptions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ready.json")
        let argv = ["--host", "127.0.0.1", "--port", "0", "--ready-file", path.path, "--nonce", "0123456789abcdef"]
        let options = try FixtureOptions(arguments: argv);try options.publish(port: 43210)
        let before = try Data(contentsOf: path)
        #expect(throws: (any Error).self) { try options.publish(port: 43211) }
        #expect(try Data(contentsOf: path) == before)
        var foreign = argv; foreign[1] = "0.0.0.0"
        #expect(throws: FixtureFailure.self) { _ = try FixtureOptions(arguments: foreign) }
    }
}

@Suite(.serialized) struct NativeFixtureSubprocess {
    @Test(arguments: [false, true]) func ownedReadyListenerHostSIGTERMAndOpenStreamJoin(_ subscribed: Bool) async throws {
        guard let executable = ProcessInfo.processInfo.environment["MCP_REFEREE_FIXTURE"] else { throw FixtureFailure.arguments }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("native-referee-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ready = directory.appendingPathComponent("ready.json"), log = directory.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log);defer { try? output.close() }
        let process = Process();process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--host","127.0.0.1","--port","0","--ready-file",ready.path,"--nonce","0123456789abcdef"]
        process.standardInput = FileHandle.nullDevice;process.standardOutput = output;process.standardError = output
        try process.run()
        defer { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL);process.waitUntilExit() } }
        let end = ContinuousClock.now.advanced(by: .seconds(40))
        while !FileManager.default.fileExists(atPath: ready.path) {
            try Task.checkCancellation();guard process.isRunning, ContinuousClock.now < end else { throw FixtureFailure.readiness }
            try await Task.sleep(for: .milliseconds(10))
        }
        let record = try WireCodec.parse(Array(Data(contentsOf: ready)), limits: .balanced).result
        #expect(try record.objectValue?["pid"]?.numberValue?.integer(as: Int32.self, limits: .balanced) == process.processIdentifier)
        #expect(record.objectValue?["nonce"]?.stringValue == "0123456789abcdef")
        let url = try #require(record.objectValue?["url"]?.stringValue)
        for (host, expected) in [(nil as String?, 200), ("evil.example", 403)] {
            let response = try await curl(url, host: host, directory: directory)
            #expect(response.status == expected)
            if expected == 200 { #expect(response.body.contains("This is a simple text response for testing.")) }
        }
        // Owned real HTTP requests exercise concurrent inspection and SSE writes.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for id in 1000..<1003 {
                group.addTask { try await self.curl(url, host: nil, directory: directory, method: "tools/list", id: id).status }
            }
            for try await code in group { #expect(code == 200) }
        }
        var stream: Process?, streamHandle: FileHandle?, streamBody: URL?
        defer {
            if let stream, stream.isRunning { _ = Darwin.kill(stream.processIdentifier, SIGKILL);stream.waitUntilExit() }
            try? streamHandle?.close()
        }
        if subscribed {
            let input = directory.appendingPathComponent("subscription"),body = directory.appendingPathComponent("stream")
            try request("subscriptions/listen", id: 2, fields: #", "notifications":{"toolsListChanged":true}"#).write(to: input)
            _ = FileManager.default.createFile(atPath: body.path, contents: nil)
            let handle = try FileHandle(forWritingTo: body);streamHandle = handle;streamBody = body
            let client = Process();client.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            client.arguments = ["-sS","-N","--max-time","15","--noproxy","*","-H","Content-Type: application/json","-H","Accept: application/json, text/event-stream","-H","MCP-Protocol-Version: 2026-07-28","-H","Mcp-Method: subscriptions/listen","--data-binary","@" + input.path,url]
            client.standardOutput = handle;client.standardError = FileHandle.nullDevice
            try client.run();stream = client
            let ack = ContinuousClock.now.advanced(by: .seconds(5))
            while !(try String(contentsOf: body, encoding: .utf8)).contains("notifications/subscriptions/acknowledged") {
                guard client.isRunning, ContinuousClock.now < ack else { throw FixtureFailure.readiness }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        process.terminate()
        let shutdown = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning || (stream?.isRunning ?? false) {
            guard ContinuousClock.now < shutdown else { throw FixtureFailure.ownership };try await Task.sleep(for: .milliseconds(5))
        }
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("FIXTURE_STOPPED started=2 joined=2 active=0"))
        if let stream, let streamBody {
            #expect(stream.terminationStatus == 0)
            let bytes = try String(contentsOf: streamBody, encoding: .utf8)
            // Server-initiated subscription teardown sends cancellation, then
            // the graceful complete result on this still-writable SSE stream.
            let cancelled = try #require(bytes.range(of: "notifications/cancelled"))
            let complete = try #require(bytes.range(of: #""resultType":"complete""#))
            #expect(cancelled.lowerBound < complete.lowerBound)
            #expect(bytes.components(separatedBy: "notifications/cancelled").count == 2)
            #expect(bytes.components(separatedBy: #""resultType":"complete""#).count == 2)
        }
    }
    @concurrent private func curl(_ url: String, host: String?, directory: URL, method: String = "tools/call", id: Int = 1) async throws -> (status: Int, body: String) {
        let input = directory.appendingPathComponent(UUID().uuidString),body = directory.appendingPathComponent(UUID().uuidString),status = directory.appendingPathComponent(UUID().uuidString)
        try request(method, id: id, fields: method == "tools/call" ? #", "name":"test_simple_text","arguments":{}"# : "").write(to: input)
        _ = FileManager.default.createFile(atPath: status.path, contents: nil)
        let handle = try FileHandle(forWritingTo: status);defer { try? handle.close() }
        let process = Process();process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        var arguments = ["-sS","--max-time","5","--noproxy","*","-o",body.path,"-w","%{http_code}","-H","Content-Type: application/json","-H","Accept: application/json, text/event-stream","-H","MCP-Protocol-Version: 2026-07-28","-H","Mcp-Method: " + method,"--data-binary","@" + input.path]
        if method == "tools/call" { arguments += ["-H", "Mcp-Name: test_simple_text"] }
        if let host { arguments += ["-H","Host: " + host] };arguments.append(url)
        process.arguments = arguments;process.standardOutput = handle;process.standardError = FileHandle.nullDevice;try process.run()
        defer { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL);process.waitUntilExit() } }
        let end = ContinuousClock.now.advanced(by: .seconds(6))
        while process.isRunning { try Task.checkCancellation();guard ContinuousClock.now < end else { throw FixtureFailure.ownership };try await Task.sleep(for: .milliseconds(2)) }
        guard process.terminationStatus == 0, let code = Int(try String(contentsOf: status, encoding: .utf8)) else { throw FixtureFailure.ownership }
        return (code, try String(contentsOf: body, encoding: .utf8))
    }
}
