// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import MCPHTTP
import MCPHTTPAuthorization
import MCPProtocol
import MCPServer
import NIOHTTPServer

@main struct HTTPExternalConsumer {
    static func main() async {
        do { try await run() }
        catch let SmokeFailure.check(label) {
            print("H5_CONSUMER_FAILED checkpoint=\(label)")
            exit(1)
        } catch {
            // Do not print credential-bearing URLs or arbitrary provider errors.
            print("H5_CONSUMER_FAILED type=\(String(reflecting: type(of: error)))")
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        try require(args.count == 6, "arguments: mode port issuer CA cert key")
        let streaming = args[0] == "sse"
        try require(streaming || args[0] == "json", "response mode")
        guard let port = Int(args[1]), (1...65535).contains(port),
              let token = ProcessInfo.processInfo.environment["MCP_CONSUMER_SYNTHETIC_TOKEN"],
              !token.isEmpty else { throw SmokeFailure.check("synthetic setup") }
        let issuer = args[2], resource = "https://127.0.0.1:\(port)/mcp"
        let endpoint = URL(string: resource)!
        let effects = Counter()
        let server = try await makeServer(resource: resource, streaming: streaming, effects: effects)
        let metadata = try await ProtectedResourceMetadata(resource: ScalarText(resource), authorizationServers: [issuer], scopes: ["read"])
        let middleware = try AuthorizationMiddleware(verifier: Verifier(token: token, issuer: issuer), resource: metadata.resource,
            issuers: [ScalarText(issuer)], policy: ScopePolicy(baseline: [ScalarText("read")]),
            now: { Int64(Date().timeIntervalSince1970) })
        let security: HTTPTransport.Security = .protectedResource(try HTTPAuthorizationPolicy(middleware: middleware, metadata: metadata),
            .x509(.pemBytes(certificateChain: Array(try Data(contentsOf: URL(fileURLWithPath: args[4]))),
                            privateKey: Array(try Data(contentsOf: URL(fileURLWithPath: args[5]))))))
        let transport = try HTTPTransport(server: server, configuration: .init(port: port,
            authority: AuthorityPolicy(authorities: ["127.0.0.1"], origins: [], portPolicy: .boundListener),
            security: security, responseMode: streaming ? .sse : .json, connections: 8, ioMilliseconds: 5000, drainMilliseconds: 1000))
        let ready = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy: .bufferingNewest(1))
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                defer { ready.continuation.finish() }
                do { try await transport.run { address in ready.continuation.yield(address) } }
                catch is CancellationError {}
            }
            do {
                var it = ready.stream.makeAsyncIterator()
                guard let bound = await it.next() else { throw SmokeFailure.check("listener readiness") }
                try require(bound.tls && bound.port == port, "TLS listener identity")
                try await exercise(endpoint: endpoint, issuer: issuer, token: token, ca: args[3], resource: resource, streaming: streaming, effects: effects)
                await transport.shutdown()
                try await group.waitForAll()
            } catch {
                await transport.shutdown()
                group.cancelAll()
                throw error
            }
        }
        let c = await server.activity, h = await transport.activity
        try require(c.active == 0 && c.queued == 0 && c.requests == 0 && c.leases == 0
            && c.bufferedBytes == 0 && c.eventBytes == 0 && c.subscriptions == 0
            && c.inspections == 0 && c.queuedInspections == 0 && h.connections == 0
            && h.requests == 0 && h.writeTimeouts == 0, "joined owners")
        passed("joined")
        print("H5_CONSUMER mode=\(args[0]) COMPLETE")
    }
}
