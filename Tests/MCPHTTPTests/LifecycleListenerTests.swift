// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPServiceLifecycle

private final class LifecycleClientFlag: Sendable {
    let value = Mutex(false), output = Mutex<URL?>(nil)
    func sawAcknowledgement() -> Bool {
        guard let url = output.withLock({ $0 }), let file = try? FileHandle(forReadingFrom:url) else { return false }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount:16_384) else { return false }
        return String(decoding:data,as:UTF8.self).contains("notifications/subscriptions/acknowledged")
    }
}
private struct LifecycleAccess: HTTPAccessPolicy {
    let principal: VerifiedPrincipal
    func authenticate(headers:HeaderFields) async throws -> VerifiedPrincipal { principal }
    func authorize(_ principal:VerifiedPrincipal,method:WireMethod,name:ScalarText?) throws {}
    func metadata(path:String) -> HTTPStaticResponse? { nil }
}
private func lifecycleWait(_ predicate:@escaping @Sendable () async -> Bool) async throws {
    let end = ContinuousClock.now.advanced(by:.seconds(5))
    while !(await predicate()) { guard ContinuousClock.now < end else { throw CoreFailure.deadline }; try await Task.sleep(for:.milliseconds(2)) }
}
// Owned finite subprocess client. No unbounded pipe capture or sleeping process
// survives the enclosing structured scope. curl's trust check uses synthetic PEMs.
@concurrent private func subscriptionClient(_ address:HTTPTransport.Address, body:Data, started:LifecycleClientFlag) async throws -> Int32 {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-http-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let input = directory.appendingPathComponent("input"), output = directory.appendingPathComponent("output")
    try body.write(to:input); started.output.withLock { $0 = output }
    let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
    var args = ["--silent","--show-error","--no-buffer","--http1.1","--max-time","8","--noproxy","*","--output",output.path,"--data-binary","@"+input.path,
        "--header","Host: localhost","--header","Accept: application/json, text/event-stream","--header","Content-Type: application/json",
        "--header","MCP-Protocol-Version: 2026-07-28","--header","Mcp-Method: subscriptions/listen"]
    if address.tls { args += ["--cacert",try #require(Bundle.module.url(forResource:"test-cert",withExtension:"pem",subdirectory:"Resources")).path] }
    args.append("\(address.tls ? "https" : "http")://127.0.0.1:\(address.port)/mcp")
    process.arguments = args; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    let cancelled = Mutex(false)
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,any Error>) in
            process.terminationHandler = { _ in c.resume() }
            do { try process.run(); started.value.withLock { $0 = true }; if cancelled.withLock({ $0 }) { process.terminate() } }
            catch { c.resume(throwing:error) }
        }
    } onCancel: { cancelled.withLock { $0 = true }; if process.isRunning { process.terminate() } }
    return process.terminationStatus
}

@Suite(.serialized) struct NativeLifecycleHTTP {
    @Test(arguments:[false,true]) func boundReadinessClosesAcceptedSubscriptionChannelsAndListener(tls:Bool) async throws {
        let core = try await Server.make(info:JSONParser().parseWithReport(Array(#"{"name":"owned-http","version":"1"}"#.utf8)).result,catalog:ServerCatalog(),
            cursors:CursorProtector(keys:[.init(identifier:ScalarText("k"),material:Data(repeating:4,count:32))],active:ScalarText("k"),clock:{1000}))
        let principal = VerifiedPrincipal(subject:ScalarText("local"),issuer:ScalarText("test"),resource:ScalarText("loopback"),scopes:[])
        let security:HTTPTransport.Security
        if tls {
            let cert = try #require(Bundle.module.url(forResource:"test-cert",withExtension:"pem",subdirectory:"Resources")), key = try #require(Bundle.module.url(forResource:"test-key",withExtension:"pem",subdirectory:"Resources"))
            security = .protectedResource(LifecycleAccess(principal:principal),.x509(.pemBytes(certificateChain:Array(try Data(contentsOf:cert)),privateKey:Array(try Data(contentsOf:key)))))
        } else { security = .loopbackDevelopment(principal) }
        let transport = try HTTPTransport(server:core,configuration:.init(admission:HTTPAdmission(),authority:AuthorityPolicy(authorities:["localhost"],origins:[]),security:security,drainMilliseconds:100))
        let address = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let component = try TransportService(name:"http",run:{ ready in
            defer { address.continuation.finish() }
            try await transport.run { value in try await ready(); address.continuation.yield(value) }
        },shutdown:{ await transport.shutdown() })
        let service = try ServerService(server:core,components:[component],policy:DrainCoordinator(drainMilliseconds:2000))
        let bytes = Data(#"{"jsonrpc":"2.0","id":1,"method":"subscriptions/listen","params":{"notifications":{"toolsListChanged":true},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#.utf8)
        let clientStarted = LifecycleClientFlag(), clientStatus = Mutex<Int32?>(nil), bound = Mutex<HTTPTransport.Address?>(nil)
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { service.requestShutdown(); group.cancelAll() }
            group.addTask { try await service.run() }
            var iterator = address.stream.makeAsyncIterator()
            let value = try #require(await iterator.next()); bound.withLock { $0 = value }
            try await lifecycleWait { await service.readiness.state == .ready }
            #expect(await service.readiness.state == .ready)
            group.addTask { clientStatus.withLock { $0 = nil }; let result = try await subscriptionClient(value,body:bytes,started:clientStarted); clientStatus.withLock { $0 = result } }
            try await lifecycleWait { clientStarted.sawAcknowledgement() }
            #expect(await core.activity.subscriptions == 1)
            #expect(clientStarted.value.withLock { $0 })
            #expect(await transport.activity.connections >= 1)
            service.requestShutdown(); service.requestShutdown(); try await group.waitForAll()
        }
        #expect(clientStatus.withLock { $0 } == 0)
        let report = await service.report, activity = await core.activity, io = await transport.activity
        #expect(report.joined == 1 && report.escalated == 0 && report.failure == nil)
        #expect(activity.active == 0 && activity.subscriptions == 0 && activity.eventBytes == 0 && activity.bufferedBytes == 0)
        #expect(io.connections == 0 && io.requests == 0)
        let value = try #require(bound.withLock { $0 })
        let fd = socket(AF_INET,SOCK_STREAM,0); defer { _ = Darwin.close(fd) }
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(value.port).bigEndian; target.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to:&target) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        #expect(status == -1 && errno == ECONNREFUSED)
    }
    @Test func embeddedCancellationJoinsListenerAndCooperativeActiveProvider() async throws {
        let entered = Mutex(false), cancelled = Mutex(false)
        let tool = ToolRegistration(definition:try JSONParser().parseWithReport(Array(#"{"name":"slow","inputSchema":{"type":"object"}}"#.utf8)).result) { _,_ in
            entered.withLock { $0 = true }
            do { try await Task.sleep(for:.seconds(30)) } catch { cancelled.withLock { $0 = true }; throw error }
            throw CoreFailure.invalidOutput
        }
        let core = try await Server.make(info:JSONParser().parseWithReport(Array(#"{"name":"cancel-http","version":"1"}"#.utf8)).result,catalog:ServerCatalog(tools:[tool]),cursors:CursorProtector(keys:[.init(identifier:ScalarText("k"),material:Data(repeating:4,count:32))],active:ScalarText("k"),clock:{1000}))
        let transport = try HTTPTransport(server:core,configuration:.init(admission:HTTPAdmission(),authority:AuthorityPolicy(authorities:["localhost"],origins:[]),security:.loopbackDevelopment(.init(subject:ScalarText("local"),issuer:ScalarText("host"),resource:ScalarText("loopback"),scopes:[])),drainMilliseconds:50))
        let ready = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let component = try TransportService(name:"http",run:{ mark in defer { ready.continuation.finish() }; try await transport.run { value in try await mark(); ready.continuation.yield(value) } },shutdown:{ await transport.shutdown() })
        let service = try ServerService(server:core,components:[component],policy:DrainCoordinator(drainMilliseconds:100))
        try await withThrowingTaskGroup(of:Void.self) { group in
            defer { service.requestShutdown(); group.cancelAll() }
            group.addTask { await #expect(throws:CancellationError.self) { try await service.run() } }
            var iterator = ready.stream.makeAsyncIterator(); let address = try #require(await iterator.next())
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/curl"); process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.arguments = ["--silent","--max-time","8","--noproxy","*","--header","Host: localhost","--header","Content-Type: application/json","--header","Accept: application/json, text/event-stream","--header","MCP-Protocol-Version: 2026-07-28","--header","Mcp-Method: tools/call","--header","Mcp-Name: slow","--data-binary",#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}"#,"http://127.0.0.1:\(address.port)/mcp"]
            // Termination is independently finite; it is joined before this scope exits.
            group.addTask {
                await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in process.terminationHandler = { _ in c.resume() }; do { try process.run() } catch { c.resume() } }
            }
            try await lifecycleWait { entered.withLock { $0 } }; group.cancelAll(); try await group.waitForAll()
        }
        #expect(cancelled.withLock { $0 })
        #expect(await service.report.joined == 1); #expect(await service.readiness.state == .stopped)
        let io = await transport.activity, activity = await core.activity
        #expect(io.connections == 0 && io.requests == 0 && activity.active == 0 && activity.bufferedBytes == 0)
    }
}
