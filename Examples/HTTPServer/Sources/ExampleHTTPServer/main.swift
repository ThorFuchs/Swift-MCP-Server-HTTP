// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import CryptoKit
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPHTTPAuthorization
import MCPServiceLifecycle
import NIOHTTPServer
import Logging
import ServiceLifecycle
import ExampleSupport

// Synthetic/demo opaque-token verifier. Replace this with your actual resource-
// server verifier; the SDK neither owns credentials nor implements an auth server.
private struct ExampleVerifier: TokenVerifier {
    let digest: SHA256.Digest
    func verify(_ bearerToken: String, forResource resource: ScalarText) async throws -> VerifiedAccessToken {
        try Task.checkCancellation()
        guard SHA256.hash(data: Data(bearerToken.utf8)) == digest else { throw AuthorizationMiddleware.Failure.invalidToken }
        return .init(principal: .init(subject: ScalarText("demo"), issuer: ScalarText("https://issuer.example.invalid"), resource: resource, scopes: [ScalarText("demo")]), expiresAtUnixSeconds: Int64(Date().timeIntervalSince1970) + 60)
    }
}
@main struct ExampleHTTPServer {
    enum Finished: Sendable { case runtime, ready }
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data("EXAMPLE_FAILED\n".utf8)); Darwin.exit(1) }
    }
    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) throws -> String? {
            guard let i = args.firstIndex(of: name) else { return nil }
            guard i + 1 < args.count else { throw CoreFailure.invalidInput }; return args[i + 1]
        }
        let portText = try option("--port")
        guard portText == nil || Int(portText!) != nil else { throw CoreFailure.invalidInput }
        let port = portText.flatMap(Int.init) ?? 0
        let certificate = try option("--tls-certificate"), privateKey = try option("--tls-key")
        let security: HTTPTransport.Security, tls: Bool
        if let certificate, let privateKey {
            guard let token = ProcessInfo.processInfo.environment["MCP_EXAMPLE_BEARER_TOKEN"], token.utf8.count >= 16, token.utf8.count <= 4096 else { throw CoreFailure.invalidInput }
            let resource = ScalarText(try option("--resource") ?? "https://localhost/mcp")
            let middleware = try AuthorizationMiddleware(verifier: ExampleVerifier(digest: SHA256.hash(data: Data(token.utf8))), resource: resource,
                issuers: [ScalarText("https://issuer.example.invalid")], policy: ScopePolicy(baseline: [ScalarText("demo")]), now: { Int64(Date().timeIntervalSince1970) })
            let metadata = try await ProtectedResourceMetadata(resource: resource, authorizationServers: ["https://issuer.example.invalid"], scopes: ["demo"])
            func boundedFile(_ path: String) throws -> Data {
                let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
                let data = try file.read(upToCount: 65537) ?? Data()
                guard data.count <= 65536 else { throw CoreFailure.limit }; return data
            }
            let cert = try boundedFile(certificate), key = try boundedFile(privateKey)
            security = .protectedResource(try HTTPAuthorizationPolicy(middleware: middleware, metadata: metadata), .x509(.pemBytes(certificateChain: Array(cert), privateKey: Array(key))))
            tls = true
        } else {
            guard certificate == nil, privateKey == nil else { throw CoreFailure.invalidInput }
            // Explicit loopback development identity, never self-reported clientInfo.
            security = .loopbackDevelopment(.init(subject: ScalarText("local-demo"), issuer: ScalarText("example-host"), resource: ScalarText("http-demo"), scopes: [])); tls = false
        }
        let server = try await ExampleCatalog.make(extensions: args.contains("--extensions"))
        let scheme = tls ? "https" : "http"
        let authority = try AuthorityPolicy(authorities: ["127.0.0.1", "localhost"], origins: [scheme + "://127.0.0.1", scheme + "://localhost"], portPolicy: .boundListener, originPortPolicy: .boundListener)
        let transport = try HTTPTransport(server: server, configuration: .init(port: port, authority: authority, security: security, responseMode: args.contains("--sse") ? .sse : .json, connections: 16, ioMilliseconds: 5000, drainMilliseconds: 1000))
        let address = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let component = try TransportService(name: "http", run: { ready in
            defer { address.continuation.finish() }
            try await transport.run { bound in address.continuation.yield(bound); try await ready() }
        }, shutdown: { await transport.shutdown() })
        let runtime = try ServerService(server: server, components: [component])
        let logger = Logger(label: "example", factory: { _ in SwiftLogNoOpLogHandler() })
        var config = ServiceGroupConfiguration(services: [.init(service: runtime, successTerminationBehavior: .gracefullyShutdownGroup, failureTerminationBehavior: .cancelGroup)], logger: logger)
        config.gracefulShutdownSignals = [.sigterm, .sigint]
        config.maximumGracefulShutdownDuration = nil; config.maximumCancellationDuration = nil
        let lifecycle = ServiceGroup(configuration: config)
        try await withThrowingTaskGroup(of: Finished.self) { group in
            group.addTask { try await lifecycle.run(); return .runtime }
            group.addTask {
                var it = address.stream.makeAsyncIterator()
                guard let bound = await it.next() else { throw CoreFailure.invalidOutput }
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while await runtime.readiness.state != .ready { try Task.checkCancellation(); guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }; try await Task.sleep(for: .milliseconds(2)) }
                FileHandle.standardError.write(Data("EXAMPLE_READY port=\(bound.port) tls=\(tls ? 1 : 0)\n".utf8))
                return .ready
            }
            defer { group.cancelAll() }
            while let result = try await group.next() { if result == .runtime { break } }
        }
        let report = await runtime.report, activity = await server.activity, io = await transport.activity
        guard report.joined == 1, report.failure == nil, activity.active == 0, activity.requests == 0,
              activity.bufferedBytes == 0, activity.eventBytes == 0, io.connections == 0, io.requests == 0 else { throw CoreFailure.invalidOutput }
        FileHandle.standardError.write(Data("EXAMPLE_STOPPED joined=1 active=0\n".utf8))
    }
}
