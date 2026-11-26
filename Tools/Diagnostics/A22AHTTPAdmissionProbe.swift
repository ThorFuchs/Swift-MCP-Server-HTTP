// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
import MCPClient
import MCPHTTPClient

// Diagnostic overlay only: use the real public HTTP transport against a
// finite synthetic loopback SSE peer. No production or fixture edits.
enum A22AProbeCase: String, CaseIterable, Sendable {
    case validSubset = "valid-subset"
    case callbackError = "callback-error"
    case beforeACK = "before-ack"
    case foreignACK = "foreign-ack"
    case duplicateACK = "duplicate-ack"
    case expandedACK = "expanded-ack"
    case foreignEvent = "foreign-event"
    case unacknowledgedEvent = "unacknowledged-event"
    case foreignTerminal = "foreign-terminal"
    case resourceURI = "resource-uri"
    case extensionValid = "extension-valid"
    case extensionForeign = "extension-foreign"
    case noACK = "no-ack"
    case afterTerminal = "after-terminal"

    var filter: SubscriptionFilter {
        switch self {
        case .validSubset, .unacknowledgedEvent:
            .init(toolsListChanged: true, promptsListChanged: true)
        case .resourceURI:
            .init(resourceSubscriptions: ["file:///one", "file:///two"])
        case .extensionValid, .extensionForeign:
            .init(extensions: ["taskIds": .array([.string("t1"), .string("t2")])])
        default: .init(toolsListChanged: true)
        }
    }
    var callbacks: [String] {
        switch self {
        case .validSubset: ["ack", "tools"]
        case .extensionValid: ["ack", "extension"]
        case .beforeACK, .foreignACK, .expandedACK, .noACK: []
        default: ["ack"]
        }
    }
    var verdict: String {
        switch self {
        case .validSubset, .extensionValid: "complete"
        case .callbackError: "callbackError"
        default: "invalidResponse"
        }
    }
}

private enum A22ACallbackFailure: Error { case stop }

@Suite(.serialized) struct A22AHTTPAdmissionProbe {
    @Test(arguments: A22AProbeCase.allCases)
    func receivesOnlyAdmittedFrames(_ scenario: A22AProbeCase) async throws {
        let base = try #require(ProcessInfo.processInfo.environment["MCP_A22A_PROBE_URL"])
        let url = try #require(URL(string: base + "/" + scenario.rawValue))
        let client = Client(transport: HTTPClientTransport(endpoint: url))
        let observed = Mutex<[String]>([])
        let verdict: String
        do {
            try await client.listen(scenario.filter) { event in
                let label: String
                switch event {
                case .acknowledged(let raw):
                    label = "ack"
                    if scenario == .validSubset {
                        #expect(raw.objectValue?["toolsListChanged"]?.booleanValue == true)
                        #expect(raw.objectValue?["promptsListChanged"] == nil)
                    }
                    if scenario == .extensionValid {
                        #expect(raw.objectValue?["taskIds"]?.arrayValue?.compactMap(\.stringValue) == ["t1"])
                    }
                case .toolsChanged: label = "tools"
                case .promptsChanged: label = "prompts"
                case .resourcesChanged: label = "resources"
                case .resourceUpdated: label = "resource"
                case .notification(let method, let params):
                    label = "extension"
                    if scenario == .extensionValid {
                        #expect(method == "notifications/tasks")
                        #expect(params.objectValue?["taskId"]?.stringValue == "t1")
                        #expect(params.objectValue?["status"]?.stringValue == "completed")
                    }
                }
                observed.withLock { $0.append(label) }
                if scenario == .callbackError { throw A22ACallbackFailure.stop }
            }
            verdict = "complete"
        } catch ClientError.invalidResponse(_) {
            verdict = "invalidResponse"
        } catch A22ACallbackFailure.stop {
            verdict = "callbackError"
        }
        let callbacks = observed.withLock { $0 }
        #expect(verdict == scenario.verdict)
        #expect(callbacks == scenario.callbacks)
        print("A22A_HTTP case=\(scenario.rawValue) verdict=\(verdict) callbacks=\(callbacks.joined(separator: ","))")
    }
}
