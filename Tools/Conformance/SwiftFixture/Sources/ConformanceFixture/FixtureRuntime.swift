// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPServiceLifecycle

/// One fixture-owned mutable catalog coordinator. An explicit shutdown clears
/// its server reference and breaks the registration/host ownership cycle.
public actor FixtureEvents {
    private var server: Server?
    private var revision = 0
    private var busy = false
    private var dynamicTools = false
    private var dynamicPrompts = false
    func bind(_ server: Server) { self.server = server }
    public func clear() { server = nil }
    func mutate(_ event: SubscriptionEvent) async throws {
        guard let server, !busy, revision < 64 else { throw CoreFailure.limit }
        busy = true; defer { busy = false }
        // Register each dynamic synthetic entry once. Subsequent hooks model
        // externally changed backing content and publish the reference event;
        // they do not recompile an unchanged full catalog on every request.
        let tools = dynamicTools || { if case .toolsChanged = event { return true }; return false }()
        let prompts = dynamicPrompts || { if case .promptsChanged = event { return true }; return false }()
        let started = ContinuousClock.now
        var construction: Int64 = 0, preparationPublication: Int64 = 0
        if tools != dynamicTools || prompts != dynamicPrompts {
            let catalog = try FixtureCatalog.make(events: self, dynamicTools: tools, dynamicPrompts: prompts)
            let built = ContinuousClock.now
            construction = nanoseconds(started.duration(to: built))
            try await server.replaceCatalog(catalog)
            preparationPublication = nanoseconds(built.duration(to: .now))
            dynamicTools = tools; dynamicPrompts = prompts
        }
        revision += 1
        let notifying = ContinuousClock.now
        try await server.publish(event, audience: .requiringScopes([]))
        let notificationAdmission = nanoseconds(notifying.duration(to: .now))
        let kind: String
        switch event { case .toolsChanged: kind = "tools"; case .promptsChanged: kind = "prompts"; default: kind = "resource" }
        FileHandle.standardError.write(Data("FIXTURE_MUTATION kind=\(kind) construction_ns=\(construction) preparation_publication_ns=\(preparationPublication) notification_admission_ns=\(notificationAdmission) total_ns=\(nanoseconds(started.duration(to: .now)))\n".utf8))
    }
    private func nanoseconds(_ duration: Duration) -> Int64 {
        let parts = duration.components, first = parts.seconds.multipliedReportingOverflow(by: 1000000000)
        let sum = first.partialValue.addingReportingOverflow(parts.attoseconds / 1000000000)
        return first.overflow || sum.overflow ? Int64.max : sum.partialValue
    }
}
public struct FixtureRuntime: Sendable {
    public let server: Server
    public let transport: HTTPTransport
    public let events: FixtureEvents
    public static func make() async throws -> Self {
        let preparationStart = ContinuousClock.now
        let events = FixtureEvents()
        let cursorMaterial = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let stateMaterial = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let epoch = ScalarText(UUID().uuidString)
        let server = try await Server.make(info: FixtureJSON.parse(#"{"name":"swift-conformance-everything-server","version":"0.1"}"#),
            catalog: FixtureCatalog.make(events: events), cursors: CursorProtector(keys: [.init(identifier: ScalarText("fixture"), material: cursorMaterial)], active: ScalarText("fixture"), epoch: epoch, clock: now),
            configuration: ServerConfiguration(deadlineMilliseconds: 60000, bufferedBytes: 67_108_864,
                preparation: ServerPreparationPolicy(work: 512_000_000, compilation: 256_000_000, evaluation: 128_000_000)),
            continuations: RequestStateProtector(keys: [.init(identifier: ScalarText("fixture"), material: stateMaterial)], active: ScalarText("fixture"), namespace: ScalarText("referee-fixture"), epoch: epoch, clock: now),
            events: EventPolicy(subscriptionLifetimeMilliseconds: 60000, logRedactor: { value in value }),
            instrumentation: FixtureDiagnostics())
        let duration = preparationStart.duration(to: .now).components
        FileHandle.standardError.write(Data("FIXTURE_COLD_PREPARATION seconds=\(duration.seconds) attoseconds=\(duration.attoseconds)\n".utf8))
        await events.bind(server)
        let transport = try HTTPTransport(server: server, configuration: .init(
            authority: AuthorityPolicy(authorities: ["127.0.0.1", "localhost", "[::1]"], origins: ["http://127.0.0.1", "http://localhost", "http://[::1]"],
                portPolicy: .boundListener, originPortPolicy: .boundListener),
            security: .loopbackDevelopment(.init(subject: ScalarText("referee"), issuer: ScalarText("fixture"), resource: ScalarText("mcp"), scopes: [])),
            responseMode: .sse, connections: 32, ioMilliseconds: 20000, drainMilliseconds: 1000))
        return .init(server: server, transport: transport, events: events)
    }
    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public func clear() async { await events.clear() }
}

/// Synthetic host diagnostics contain fixed classifications only. They never
/// reflect request IDs, identity, JSON input or continuation state.
private struct FixtureDiagnostics: ServerRequestInstrumentation {
    func withRequest(_ request: DiagnosticRequest, operation: @escaping @Sendable () async throws -> DiagnosticOutcome) async throws {
        do { _ = try await operation() }
        catch {
            let classification = (error as? CoreFailure).map { String(describing: $0) } ?? String(describing: type(of: error))
            FileHandle.standardError.write(Data("FIXTURE_REQUEST_FAILURE \(classification)\n".utf8))
            throw error
        }
    }
}
