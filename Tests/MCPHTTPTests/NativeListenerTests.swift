// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
import Synchronization
import Testing
import JSON
import MCPProtocol
import MCPServer
import MCPHTTP
import MCPHTTPAuthorization
import NIOHTTPServer

/// Peer-close (FIN) detection while no read is pending needs SwiftNIO's early EOF delivery,
/// which upstream SwiftNIO still disables on Darwin. Fixed by apple/swift-nio#3783; remove
/// these known issues once a SwiftNIO release with that change is required.
let macOSEarlyEOFKnownIssue: Comment = "Needs SwiftNIO early EOF on macOS 27 (apple/swift-nio#3783)"

private func parseHTTP(_ text:String) throws -> JSON { try JSONParser().parseWithReport(Array(text.utf8)).result }
private func httpResource(_ name:String) throws -> URL {
    try #require(Bundle.module.url(forResource:name,withExtension:"pem",subdirectory:"Resources"))
}
private let anonymousHTTP = VerifiedPrincipal(subject:ScalarText("anonymous"),issuer:ScalarText("development"),resource:ScalarText("loopback"),scopes:[])
private func httpCore(tools:[ToolRegistration] = [], events:EventPolicy? = nil, configuration:ServerConfiguration? = nil) async throws -> Server {
    try await Server.make(info:parseHTTP(#"{"name":"http-test","version":"1"}"#),catalog:ServerCatalog(tools:tools),
        cursors:CursorProtector(keys:[.init(identifier:ScalarText("http"),material:Data(repeating:5,count:32))],active:ScalarText("http"),clock:{1000}),configuration:configuration,events:events)
}
private func rpcHTTP(method:String = "tools/list", id:Int = 1, params:String = "") -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"\(method)\",\"params\":{\(params)\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}".utf8)
}
private func withHTTP(_ server:Server,security:HTTPTransport.Security = .loopbackDevelopment(anonymousHTTP),
    mode:HTTPTransport.ResponseMode = .json, io:Int64 = 5000,drain:Int64 = 100,
    maximumBody:Int = 1_048_576,connections:Int = 8,
    body:@escaping @Sendable (HTTPTransport.Address,HTTPTransport) async throws -> Void) async throws {
    let transport = try HTTPTransport(server:server,configuration:.init(
        admission:HTTPAdmission(maximumBodyBytes:maximumBody),authority:AuthorityPolicy(authorities:["localhost"],origins:["https://allowed.example"]),
        security:security,responseMode:mode,connections:connections,ioMilliseconds:io,drainMilliseconds:drain))
    let ready = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy:.bufferingNewest(1))
    async let run:Void = runHTTP(transport,ready:ready.continuation)
    var iterator = ready.stream.makeAsyncIterator()
    guard let address = await iterator.next() else { try await run; throw CoreFailure.disconnected }
    try await body(address,transport)
    await transport.shutdown()
    try await run
    let activity = await server.activity
    #expect(activity.active == 0 && activity.queued == 0 && activity.requests == 0 && activity.bufferedBytes == 0 && activity.subscriptions == 0)
}
private func runHTTP(_ transport:HTTPTransport,ready:AsyncStream<HTTPTransport.Address>.Continuation) async throws {
    defer { ready.finish() }
    do { try await transport.run { address in ready.yield(address) } }
    catch is CancellationError { }
}
private struct CurlResult:Sendable { let exit:Int32,status:Int,headers:String,body:Data,stderr:String }
@concurrent private func curlHTTP(_ address:HTTPTransport.Address,data:Data? = nil,method:String = "POST",path:String = "/mcp",
    headers:[String] = [], trust:Bool = true) async throws -> CurlResult {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-http-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:directory) }
    let out = directory.appendingPathComponent("body"), head = directory.appendingPathComponent("headers")
    let process = Process(), stdout = Pipe(), stderr = Pipe()
    process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
    var arguments = ["-sS","--http1.1","--max-time","5","--noproxy","*","-X",method,
        "-D",head.path,"-o",out.path,"-w","%{http_code}","-H","Host: localhost",
        "-H","Accept: application/json, text/event-stream","-H","Content-Type: application/json",
        "-H","MCP-Protocol-Version: 2026-07-28","-H","Mcp-Method: tools/list"]
    // curl appends ordinary repeated -H fields. Replace the defaults here;
    // raw-socket cases below exercise actual duplicate-header rejection.
    let overridden = Set(headers.map { $0.split(separator:":",maxSplits:1,omittingEmptySubsequences:false)[0].lowercased() })
    var filtered:[String] = []
    var i = 0
    while i < arguments.count {
        if arguments[i] == "-H", overridden.contains(arguments[i+1].split(separator:":",maxSplits:1)[0].lowercased()) { i += 2; continue }
        filtered.append(arguments[i]); i += 1
    }
    arguments = filtered
    for header in headers { arguments += ["-H",header] }
    if address.tls && trust { arguments += ["--cacert",try httpResource("test-cert").path] }
    if let data {
        let input = directory.appendingPathComponent("input"); try data.write(to:input)
        arguments += ["--data-binary","@"+input.path]
    }
    arguments.append("\(address.tls ? "https" : "http")://127.0.0.1:\(address.port)\(path)")
    process.arguments = arguments; process.standardOutput = stdout; process.standardError = stderr
    try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void, any Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do { try process.run() } catch { continuation.resume(throwing:error) }
    }
    let diagnostics = String(decoding:stderr.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
    if process.terminationStatus != 0 { print("CURL_FAILURE status=\(process.terminationStatus) \(diagnostics)") }
    let status = Int(String(decoding:stdout.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)) ?? 0
    return .init(exit:process.terminationStatus,status:status,headers:(try? String(contentsOf:head,encoding:.utf8)) ?? "",
        body:(try? Data(contentsOf:out)) ?? Data(),stderr:diagnostics)
}
private func codeHTTP(_ result:CurlResult) throws -> Int? {
    try JSONParser().parseWithReport(Array(result.body)).result.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as:Int.self,limits:.balanced)
}







private final class HTTPCallCounter:Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count:Int { value.withLock { $0 } }
}
private struct HTTPVerifier:TokenVerifier {
    let calls:HTTPCallCounter
    func verify(_ bearerToken:String,forResource resource:ScalarText) async throws -> VerifiedAccessToken {
        calls.increment()
        if bearerToken == "fail" { throw HTTPAdmission.Failure.malformed }
        let issuer = ScalarText(bearerToken == "issuer" ? "https://wrong.example" : "https://issuer.example")
        let actual = bearerToken == "audience" ? ScalarText("https://other.example/mcp") : resource
        let scopes:Set<ScalarText> = bearerToken == "scope" ? [] : [ScalarText("read")]
        return .init(principal:.init(subject:ScalarText(bearerToken == "second" ? "second" : "first"),issuer:issuer,resource:actual,scopes:scopes),
            expiresAtUnixSeconds:bearerToken == "expired" ? 100 : 200)
    }
}
private func httpSecurity(_ calls:HTTPCallCounter = HTTPCallCounter(),verifier:(any TokenVerifier)? = nil) async throws -> HTTPTransport.Security {
    let metadata = try await ProtectedResourceMetadata(resource:ScalarText("https://localhost/mcp"),authorizationServers:["https://issuer.example"],scopes:["read"])
    let middleware = try AuthorizationMiddleware(verifier:verifier ?? HTTPVerifier(calls:calls),resource:metadata.resource,issuers:[ScalarText("https://issuer.example")],
        policy:ScopePolicy(baseline:[ScalarText("read")]),now:{100})
    let cert = try Data(contentsOf:httpResource("test-cert"))
    let key = try Data(contentsOf:httpResource("test-key"))
    return .protectedResource(try HTTPAuthorizationPolicy(middleware:middleware,metadata:metadata),.x509(.pemBytes(certificateChain:Array(cert),privateKey:Array(key))))
}




private final class HTTPTestSocket:Sendable {
    private let descriptor:Mutex<Int32>
    func constrainReceiveWindow() { var size:Int32 = 1024; let fd = descriptor.withLock { $0 }; _ = setsockopt(fd,SOL_SOCKET,SO_RCVBUF,&size,socklen_t(MemoryLayout<Int32>.size)) }
    init(_ address:HTTPTransport.Address,receiveWindow:Int32? = nil) throws {
        let fd = socket(AF_INET,SOCK_STREAM,0); guard fd >= 0 else { throw POSIXError(.ENFILE) }
        descriptor = Mutex(fd)
        if var size = receiveWindow { _ = setsockopt(fd,SOL_SOCKET,SO_RCVBUF,&size,socklen_t(MemoryLayout<Int32>.size)) }
        var timeout = timeval(tv_sec:3,tv_usec:0), one:Int32 = 1
        _ = setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,socklen_t(MemoryLayout<Int32>.size))
        var target = sockaddr_in(); target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET)
        target.sin_port = UInt16(address.port).bigEndian; target.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to:&target) { p in p.withMemoryRebound(to:sockaddr.self,capacity:1) { connect(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0 else { closeSocket(); throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
    }
    deinit { let fd = descriptor.withLock { $0 }; if fd >= 0 { _ = Darwin.close(fd) } }
    func closeSocket() { let fd = descriptor.withLock { let fd = $0; $0 = -1; return fd }; if fd >= 0 { _ = Darwin.close(fd) } }
    func send(_ data:Data) throws {
        let fd = descriptor.withLock { $0 }
        try data.withUnsafeBytes { pointer in
            var sent = 0
            while sent < pointer.count {
                let count = Darwin.send(fd,pointer.baseAddress!.advanced(by:sent),pointer.count-sent,0)
                guard count > 0 else { throw POSIXError(.EIO) }; sent += count
            }
        }
    }
    @concurrent func receive(until marker:String? = nil,maximum:Int = 8_388_608) async throws -> Data {
        let fd = descriptor.withLock { $0 }
        return try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Data, any Error>) in
            let thread = Thread {
                do { continuation.resume(returning:try Self.read(fd,marker:marker,maximum:maximum)) }
                catch { continuation.resume(throwing:error) }
            }
            thread.name = "MCP native HTTP test socket"; thread.start()
        }
    }
    private static func read(_ fd:Int32,marker:String?,maximum:Int) throws -> Data {
        var collected = Data(),buffer = [UInt8](repeating:0,count:4096)
        while collected.count < maximum {
            let count = recv(fd,&buffer,min(buffer.count,maximum-collected.count),0)
            if count == 0 { return collected }
            if count < 0 { print("SOCKET_READ_FAILURE bytes=\(collected.count) prefix=\(String(decoding:collected.prefix(1024),as:UTF8.self))"); throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO) }
            collected.append(contentsOf:buffer.prefix(count))
            if let marker, String(decoding:collected,as:UTF8.self).contains(marker) { return collected }
        }
        throw HTTPAdmission.Failure.tooLarge
    }
    func request(_ bytes:Data,method:String = "tools/list",chunked:Bool = false,close:Bool = false) throws {
        let head = "POST /mcp HTTP/1.1\r\nHost: localhost\r\nAccept: application/json, text/event-stream\r\nContent-Type: application/json\r\nMCP-Protocol-Version: 2026-07-28\r\nMcp-Method: \(method)\r\n\(method == "tools/call" ? "Mcp-Name: wait\r\n" : "")\(close ? "Connection: close\r\n" : "")\(chunked ? "Transfer-Encoding: chunked" : "Content-Length: \(bytes.count)")\r\n\r\n"
        try send(Data(head.utf8))
        if chunked {
            for start in stride(from:0,to:bytes.count,by:7) {
                let chunk = bytes[start..<min(start+7,bytes.count)]
                try send(Data("\(String(chunk.count,radix:16))\r\n".utf8)+chunk+Data("\r\n".utf8))
            }
            try send(Data("0\r\n\r\n".utf8))
        } else { try send(bytes) }
    }
}
private func waitHTTP(_ condition:@escaping @Sendable () async -> Bool,milliseconds:Int64 = 2000) async throws {
    let deadline = ContinuousClock.now.advanced(by:.milliseconds(milliseconds))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw CoreFailure.deadline }
        try await Task.sleep(for:.milliseconds(2))
    }
}

private enum StalledHTTPProviderLifetime: String, Sendable, Equatable {
    case finite, untilCancellation
}

private func exerciseStalledHTTPWriter(_ lifetime: StalledHTTPProviderLifetime) async throws {
    let entered = HTTPCallCounter(),returned = HTTPCallCounter(),cancelled = HTTPCallCounter()
    let disconnected = HTTPCallCounter(),unexpected = HTTPCallCounter()
    let attempted = HTTPCallCounter(),admitted = HTTPCallCounter(),filtered = HTTPCallCounter()
    let release = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
    defer { release.continuation.finish() }
    let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,context in
        entered.increment()
        do {
            do {
                // Finite events exercise socket backpressure without a terminal
                // result large enough to test the independent terminal-work cap.
                for _ in 1...32 {
                    attempted.increment()
                    if try await context.log(.debug,data:.string(String(repeating:"x",count:80_000))) { admitted.increment() }
                    else { filtered.increment() }
                    try await Task.sleep(for:.milliseconds(2))
                }
            } catch {
                if lifetime == .finite { throw error }
                // Logging is optional for this deliberately still-live provider.
                // A failed event sink must also cancel its separate pending work.
                // Overflow, budget failures and request deadlines remain failures.
                if !(error is CancellationError) && error as? CoreFailure != .disconnected && error as? CoreFailure != .eventsUnavailable {
                    unexpected.increment()
                    print("STALLED_LIVE_EMISSION_FAILURE \(error)")
                }
            }
            if lifetime == .untilCancellation {
                var iterator = release.stream.makeAsyncIterator()
                _ = await iterator.next() // Never released by the successful test path.
                try Task.checkCancellation()
                throw CoreFailure.invalidState
            }
            let result = try parseHTTP(#"{"resultType":"complete","content":[]}"#)
            returned.increment()
            return result
        } catch is CancellationError {
            cancelled.increment()
            throw CancellationError()
        } catch {
            if error as? CoreFailure == .disconnected || error as? CoreFailure == .eventsUnavailable { disconnected.increment() }
            else { unexpected.increment() }
            throw error
        }
    }
    let core = try await httpCore(tools:[tool],events:EventPolicy(queuedBytes:2_097_152,principalBytes:4_194_304,logIntervalMilliseconds:1,logRedactor:{$0}))
    try await withHTTP(core,mode:.sse,io:1000,connections:1) { address,transport in
        let socket = try HTTPTestSocket(address,receiveWindow:1024); defer { socket.closeSocket() }
        socket.constrainReceiveWindow()
        let request = String(decoding:rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),as:UTF8.self)
            .replacingOccurrences(of:"\"io.modelcontextprotocol/clientCapabilities\":{}",with:"\"io.modelcontextprotocol/logLevel\":\"debug\",\"io.modelcontextprotocol/clientCapabilities\":{}")
        try socket.request(Data(request.utf8),method:"tools/call")
        try await waitHTTP { entered.count == 1 }
        // Prove timeout cleanup before shutdown or reading from the stalled peer
        // can release pressure. In particular, no retained event or socket owner.
        try await waitHTTP({
            let coreState = await core.activity,transportState = await transport.activity
            return coreState.active == 0 && coreState.queued == 0 && coreState.requests == 0 && coreState.leases == 0 &&
                coreState.bufferedBytes == 0 && coreState.eventBytes == 0 && coreState.subscriptions == 0 &&
                coreState.inspections == 0 && coreState.queuedInspections == 0 &&
                transportState.requests == 0 && transportState.connections == 0
        },milliseconds:10_000)
        let partial = try await socket.receive()
        let timedOut = await transport.activity.writeTimeouts
        print("STALLED_WRITER lifetime=\(lifetime.rawValue) timeout=\(timedOut) returned=\(returned.count) cancelled=\(cancelled.count) disconnected=\(disconnected.count) unexpected=\(unexpected.count) attempted=\(attempted.count) admitted=\(admitted.count) filtered=\(filtered.count) received=\(partial.count)")
        #expect(timedOut == 1)
        #expect(entered.count == 1 && unexpected.count == 0 && admitted.count > 0)
        if lifetime == .untilCancellation {
            #expect(cancelled.count == 1 && returned.count == 0 && disconnected.count == 0)
        } else {
            // Queue admission does not acknowledge delivery. A finite provider
            // may already have returned when its still-owned writer times out.
            #expect(returned.count + cancelled.count + disconnected.count == 1)
            if returned.count == 1 { #expect(attempted.count == 32 && admitted.count == 32) }
        }
        #expect(!partial.isEmpty && partial.count < 32 * 80_000)
        let body = String(decoding:partial,as:UTF8.self)
        #expect(body.components(separatedBy:"HTTP/1.1").count == 2 && !body.contains("\"resultType\":\"complete\""))
        // With one allowed connection, success proves admission recovers while
        // this same listener remains running. Shutdown has not been called.
        let recovered = try await curlHTTP(address,data:rpcHTTP())
        #expect(recovered.exit == 0 && recovered.status == 200)
        #expect(await transport.activity.writeTimeouts == 1)
    }
}

// Real listeners share process-global NIO resources; serialize independent cases.
// Each case still orchestrates its own concurrent requests/cancellation/shutdown.
@Suite(.serialized) struct NativeHTTPListenerTests {
    @Test func nativeHTTPListenerJSONAndModernMethodFailures() async throws {
        let core = try await httpCore()
        try await withHTTP(core) { address,_ in
            let valid = try await curlHTTP(address,data:rpcHTTP())
            #expect(valid.exit == 0 && valid.status == 200)
            #expect(valid.headers.lowercased().contains("content-type: application/json"))
            #expect(try JSONParser().parseWithReport(Array(valid.body)).result.objectValue?["result"] != nil)
            for method in ["GET","DELETE","PUT"] {
                let result = try await curlHTTP(address,method:method)
                #expect(result.status == 405 && result.body.isEmpty && result.headers.contains("Allow: POST"))
            }
            let old = try await curlHTTP(address,data:rpcHTTP(method:"initialize"),headers:["Mcp-Method: initialize"])
            #expect(try old.status == 404 && codeHTTP(old) == -32601)
            let malformed = try await curlHTTP(address,data:Data([0xff]))
            #expect(try malformed.status == 400 && codeHTTP(malformed) == -32700)
        }
    }

    @Test func nativeHTTPHostOriginAndProxySpoofing() async throws {
        try await withHTTP(httpCore()) { address,_ in
            for header in ["Host: evil.example","Origin: https://evil.example","Origin: null","Origin: https://allowed.example/path","Origin: https://世界.example"] {
                let result = try await curlHTTP(address,data:rpcHTTP(),headers:[header,"Forwarded: host=localhost;proto=https","X-Forwarded-Host: localhost"])
                #expect(result.status == 403 && result.body.isEmpty)
            }
            let valid = try await curlHTTP(address,data:rpcHTTP(),headers:["Origin: https://allowed.example","X-Forwarded-Host: evil.example"])
            #expect(valid.status == 200)
        }
    }

    @Test func nativeHTTPHeaderMirrorsAndUnsupportedVersionHaveExactWireErrors() async throws {
        try await withHTTP(httpCore()) { address,_ in
            for header in ["Mcp-Method: resources/list","Mcp-Method: 世界","Mcp-Method:","MCP-Protocol-Version:","MCP-Protocol-Version: 2025-11-25"] {
                let result = try await curlHTTP(address,data:rpcHTTP(),headers:[header])
                #expect(try result.status == 400 && codeHTTP(result) == -32020)
            }
            let bytes = Data(String(decoding:rpcHTTP(),as:UTF8.self).replacingOccurrences(of:"2026-07-28",with:"2025-11-25").utf8)
            let unsupported = try await curlHTTP(address,data:bytes,headers:["MCP-Protocol-Version: 2025-11-25"])
            #expect(try unsupported.status == 400 && codeHTTP(unsupported) == -32022)
        }
    }

    @Test func nativeHTTPNestedCustomHeadersValidateBeforeEffects() async throws {
        let calls = Mutex(0)
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"header","inputSchema":{"type":"object","properties":{"nested":{"type":"object","properties":{"number":{"type":"integer","x-mcp-header":"Number"}}}}}}"#)) { _,_ in
            calls.withLock { $0 += 1 }; return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        try await withHTTP(httpCore(tools:[tool])) { address,_ in
            let bytes = rpcHTTP(method:"tools/call",params:#""name":"header","arguments":{"nested":{"number":42}},"#)
            for field in ["Mcp-Param-Number: 41","Mcp-Param-Number:","Mcp-Param-Number: =?base64?!!!!?="] {
                let result = try await curlHTTP(address,data:bytes,headers:["Mcp-Method: tools/call","Mcp-Name: header",field])
                #expect(try result.status == 400 && codeHTTP(result) == -32020)
            }
            #expect(calls.withLock { $0 } == 0)
            let valid = try await curlHTTP(address,data:bytes,headers:["Mcp-Method: tools/call","Mcp-Name: header","mcp-param-number: 42.0"])
            #expect(valid.status == 200 && calls.withLock { $0 } == 1)
            let invalid = rpcHTTP(method:"tools/call",id:2,params:#""name":"header","arguments":{"nested":{"number":"42"}},"#)
            let result = try await curlHTTP(address,data:invalid,headers:["Mcp-Method: tools/call","Mcp-Name: header","Mcp-Param-Number: 42"])
            #expect(try result.status == 400 && codeHTTP(result) == -32602 && calls.withLock { $0 } == 1)
        }
    }

    @Test func nativeHTTPAdmissionBodyMediaAcceptAndNotificationBoundaries() async throws {
        try await withHTTP(httpCore(),maximumBody:512) { address,_ in
            for (headers,status) in [(["Content-Type: text/plain"],415),(["Accept: application/json"],406)] {
                let result = try await curlHTTP(address,data:rpcHTTP(),headers:headers); #expect(result.status == status)
            }
            let tooLarge = try await curlHTTP(address,data:Data(repeating:32,count:513))
            #expect(tooLarge.status == 413)
            let wrongRoute = try await curlHTTP(address,data:rpcHTTP(),path:"/other"); #expect(wrongRoute.status == 404)
            for notification in [#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#,
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":false}"#,
                #"{"jsonrpc":"2.0","method":"notifications/unknown"}"#] {
                let result = try await curlHTTP(address,data:Data(notification.utf8))
                #expect(result.status == 400 && result.body.isEmpty)
            }
        }
    }

    @Test func nativeTLSValidatesTrustAndServesProtectedMetadata() async throws {
        let calls = HTTPCallCounter()
        try await withHTTP(httpCore(),security:httpSecurity(calls)) { address,_ in
            #expect(address.tls)
            let badTrust = try await curlHTTP(address,method:"GET",path:"/.well-known/oauth-protected-resource/mcp",trust:false)
            #expect(badTrust.exit != 0 && badTrust.status == 0)
            let metadata = try await curlHTTP(address,method:"GET",path:"/.well-known/oauth-protected-resource/mcp")
            #expect(metadata.exit == 0 && metadata.status == 200 && calls.count == 0)
            let document = try JSONParser().parseWithReport(Array(metadata.body)).result
            #expect(document.objectValue?["resource"]?.stringValue == "https://localhost/mcp")
            #expect(document.objectValue?["bearer_methods_supported"]?.arrayValue?.first?.stringValue == "header")
            let wrongOrigin = try await curlHTTP(address,method:"GET",path:"/.well-known/oauth-protected-resource/mcp",headers:["Origin: https://evil.example"])
            #expect(wrongOrigin.status == 403)
        }
    }

    @Test func nativeTLSAuthorizationChallengesScopesAndCredentialRedaction() async throws {
        let calls = HTTPCallCounter()
        try await withHTTP(httpCore(),security:httpSecurity(calls)) { address,_ in
            let absent = try await curlHTTP(address,data:rpcHTTP())
            #expect(absent.status == 401 && absent.headers.contains("resource_metadata=\"https://localhost/.well-known/oauth-protected-resource/mcp\""))
            #expect(!absent.headers.contains("invalid_token"))
            for token in ["fail","issuer","audience","expired"] {
                let result = try await curlHTTP(address,data:rpcHTTP(),headers:["Authorization: Bearer \(token)"])
                #expect(result.status == 401 && result.headers.contains("invalid_token") && result.body.isEmpty)
            }
            let denied = try await curlHTTP(address,data:rpcHTTP(),headers:["Authorization: Bearer scope"])
            #expect(denied.status == 403 && denied.headers.contains("insufficient_scope") && denied.headers.contains("scope=\"read\""))
            let valid = try await curlHTTP(address,data:rpcHTTP(),headers:["Authorization: Bearer sentinel-secret"])
            #expect(valid.status == 200 && !String(decoding:valid.body,as:UTF8.self).contains("sentinel-secret") && !valid.headers.contains("sentinel-secret"))
            let malformed = try await curlHTTP(address,data:rpcHTTP(),headers:["Authorization: Basic secret"])
            #expect(malformed.status == 401 && malformed.body.isEmpty)
            #expect(calls.count == 6)
        }
    }

    @Test func nativeHTTPSSEProgressAndTerminalAreRequestScoped() async throws {
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"events","inputSchema":{"type":"object"}}"#)) { _,context in
            try await context.progress(try JSONNumber(parsing:"1",limits:.balanced),total:try JSONNumber(parsing:"2",limits:.balanced))
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        try await withHTTP(httpCore(tools:[tool]),mode:.sse) { address,_ in
            var request = String(decoding:rpcHTTP(method:"tools/call",params:#""name":"events","arguments":{},"#),as:UTF8.self)
            request = request.replacingOccurrences(of:"\"io.modelcontextprotocol/clientCapabilities\":{}",with:"\"progressToken\":\"one\",\"io.modelcontextprotocol/clientCapabilities\":{}")
            let result = try await curlHTTP(address,data:Data(request.utf8),headers:["Mcp-Method: tools/call","Mcp-Name: events"])
            let body = String(decoding:result.body,as:UTF8.self)
            #expect(result.status == 200 && result.headers.lowercased().contains("text/event-stream") && result.headers.lowercased().contains("x-accel-buffering: no"))
            let events = body.components(separatedBy:"\n\n").filter { !$0.isEmpty }
            #expect(events.count == 2 && events.allSatisfy { $0.hasPrefix("data: ") })
            #expect(events.first?.contains("notifications/progress") == true && events.last?.contains("\"result\"") == true)
            #expect(!body.contains("id:") && !body.contains("event:") && !body.contains("notifications/cancelled"))
        }
    }

    @Test func nativeHTTPChunkFragmentsAndKeepAliveUseBoundedRawReader() async throws {
        try await withHTTP(httpCore()) { address,_ in
            let socket = try HTTPTestSocket(address)
            defer { socket.closeSocket() }
            try socket.request(rpcHTTP(),chunked:true)
            let first = try await socket.receive(until:"0\r\n\r\n")
            #expect(String(decoding:first,as:UTF8.self).contains("200 OK"))
            try socket.request(rpcHTTP(id:2),close:true)
            let second = try await socket.receive()
            #expect(String(decoding:second,as:UTF8.self).contains("200 OK"))
        }
    }

    @Test func nativeHTTPChunkedOverflowAndHeaderLimitsCloseAcceptedChannels() async throws {
        try await withHTTP(httpCore(),maximumBody:512) { address,_ in
            let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
            try socket.request(Data(repeating:32,count:513),chunked:true)
            let response = try await socket.receive()
            #expect(String(decoding:response,as:UTF8.self).contains("413"))
            let large = try HTTPTestSocket(address); defer { large.closeSocket() }
            try large.send(Data(("POST /mcp HTTP/1.1\r\nHost: localhost\r\nX-Large: "+String(repeating:"a",count:33_000)+"\r\nContent-Length: 0\r\n\r\n").utf8))
            let bounded = try await large.receive()
            #expect(String(decoding:bounded,as:UTF8.self).contains("400"))
        }
    }

    @Test func nativeHTTPStalledBodyHasFiniteTimeoutAndListenerSurvives() async throws {
        try await withHTTP(httpCore(),io:100) { address,_ in
            let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
            try socket.send(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: 100\r\n\r\n{".utf8))
            _ = try await socket.receive()
            let valid = try await curlHTTP(address,data:rpcHTTP()); #expect(valid.status == 200)
        }
    }

    @Test func nativeHTTPShutdownCancelsProviderAndClosesAcceptedSocket() async throws {
        let entered = HTTPCallCounter(),cancelled = HTTPCallCounter()
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
            entered.increment()
            do { try await Task.sleep(for:.seconds(60)) }
            catch { cancelled.increment(); throw error }
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        try await withHTTP(httpCore(tools:[tool])) { address,transport in
            let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
            socket.constrainReceiveWindow()
            try socket.request(rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),method:"tools/call")
            try await waitHTTP { entered.count == 1 }
            await transport.shutdown()
            try await waitHTTP { cancelled.count == 1 }
            _ = try await socket.receive()
            await transport.shutdown()
        }
    }

    @Test func nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion() async throws {
        await withKnownIssue(macOSEarlyEOFKnownIssue) {
        let entered = HTTPCallCounter(),cancelled = HTTPCallCounter()
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
            entered.increment()
            do { try await Task.sleep(for:.seconds(60)) }
            catch { cancelled.increment(); throw error }
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        try await withHTTP(httpCore(tools:[tool]),mode:.sse) { address,transport in
            let socket = try HTTPTestSocket(address)
            try socket.request(rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),method:"tools/call")
            try await waitHTTP { entered.count == 1 }
            socket.closeSocket()
            do { try await waitHTTP({ cancelled.count == 1 },milliseconds:1000) }
            catch { await transport.shutdown(); throw error }
            #expect(cancelled.count == 1)
        }
        }
    }

    @Test func nativeHTTPSubscriptionShutdownUsesD02CompleteThenClose() async throws {
        try await withHTTP(httpCore()) { address,transport in
            let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
            try socket.request(rpcHTTP(method:"subscriptions/listen",params:#""notifications":{"toolsListChanged":true},"#),method:"subscriptions/listen")
            let ack = try await socket.receive(until:"notifications/subscriptions/acknowledged")
            #expect(String(decoding:ack,as:UTF8.self).contains("text/event-stream"))
            await transport.shutdown()
            let tail = try await socket.receive()
            let text = String(decoding:tail,as:UTF8.self)
            // The dated cancellation rules require notifications/cancelled for the listen
            // request on server teardown (every transport), then the graceful complete result.
            let cancelled = try #require(text.range(of:"notifications/cancelled"))
            let complete = try #require(text.range(of:"\"resultType\":\"complete\""))
            #expect(cancelled.lowerBound < complete.lowerBound)
        }
    }

    @Test func nativeHTTPConfigurationRejectsAccidentalExposureAndDuplicateRun() async throws {
        #expect(throws:HTTPAdmission.Failure.invalidConfiguration) {
            _ = try HTTPTransport.Configuration(host:"0.0.0.0",authority:AuthorityPolicy(authorities:["localhost"],origins:[]),security:.loopbackDevelopment(anonymousHTTP))
        }
        try await withHTTP(httpCore()) { _,transport in
            await #expect(throws:CoreFailure.duplicate) { try await transport.run { _ in Issue.record("Duplicate listener") } }
        }
    }

    @Test func nativeHTTPRepeatedShutdownClosesIdleKeepAliveConnections() async throws {
        for _ in 0..<3 {
            try await withHTTP(httpCore()) { address,transport in
                let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
                try socket.request(rpcHTTP())
                _ = try await socket.receive(until:"0\r\n\r\n")
                await transport.shutdown()
                #expect(try await socket.receive().isEmpty)
            }
        }
    }

    @Test func nativeTLSCatalogScopeChallengePrecedesProviderEffects() async throws {
        let effects = HTTPCallCounter()
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#),requiredScopes:[ScalarText("write")]) { _,_ in
            effects.increment(); return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        try await withHTTP(httpCore(tools:[tool]),security:httpSecurity()) { address,_ in
            let result = try await curlHTTP(address,data:rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),headers:["Mcp-Method: tools/call","Mcp-Name: wait","Authorization: Bearer good"])
            #expect(result.status == 403 && result.headers.contains("scope=\"write\"") && effects.count == 0)
        }
    }

    @Test func nativeTLSVerifiedPrincipalOverridesClientInfoAcrossRequests() async throws {
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,context in
            #expect(context.principal.issuer == ScalarText("https://issuer.example") && context.principal.resource == ScalarText("https://localhost/mcp"))
            return try parseHTTP("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"\(context.principal.subject.description)\"}]}")
        }
        try await withHTTP(httpCore(tools:[tool]),security:httpSecurity()) { address,_ in
            for (token,expected) in [("sentinel-secret","first"),("second","second")] {
                let forged = String(decoding:rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),as:UTF8.self)
                    .replacingOccurrences(of:"\"io.modelcontextprotocol/clientCapabilities\":{}",with:"\"io.modelcontextprotocol/clientInfo\":{\"name\":\"forged\",\"version\":\"1\"},\"io.modelcontextprotocol/clientCapabilities\":{}")
                let result = try await curlHTTP(address,data:Data(forged.utf8),headers:["Mcp-Method: tools/call","Mcp-Name: wait","Authorization: Bearer \(token)"])
                #expect(result.status == 200)
                let text = try JSONParser().parseWithReport(Array(result.body)).result.objectValue?["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
                #expect(text == expected)
            }
        }
    }

    @Test func nativeHTTPDuplicateHostAndMirrorsHaveIndependentRejections() async throws {
        try await withHTTP(httpCore()) { address,_ in
            for (extra,status) in [("Host: evil.example\r\n",403),("Host: evil.example\r\nHost: third.example\r\n",403),("Mcp-Method: resources/list\r\n",400),("Origin: https://allowed.example\r\nOrigin: https://evil.example\r\n",403)] {
                let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
                let body = rpcHTTP()
                try socket.send(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nAccept: application/json, text/event-stream\r\nContent-Type: application/json\r\nMCP-Protocol-Version: 2026-07-28\r\nMcp-Method: tools/list\r\n\(extra)Content-Length: \(body.count)\r\n\r\n".utf8)+body)
                let result = String(decoding:try await socket.receive(until:status == 400 ? "0\r\n\r\n" : nil),as:UTF8.self)
                #expect(result.contains("\(status)"))
                // Rejected before the body was read: the connection ends, and the response says so,
                // so keep-alive clients do not reuse it (the referee's dns-rebinding scenario).
                if status == 403 { #expect(result.lowercased().contains("\r\nconnection: close\r\n")) }
                if extra.hasPrefix("Mcp") {
                    let raw = Data(result.utf8)
                    let separator = try #require(raw.range(of:Data("\r\n\r\n".utf8)))
                    var chunks = raw[separator.upperBound...], body = Data()
                    while let end = chunks.range(of:Data("\r\n".utf8)) {
                        let count = try #require(Int(String(decoding:chunks[..<end.lowerBound],as:UTF8.self),radix:16))
                        chunks = chunks[end.upperBound...]; if count == 0 { break }
                        try #require(chunks.count >= count+2); body.append(chunks.prefix(count)); chunks = chunks.dropFirst(count+2)
                    }
                    let value = try JSONParser().parseWithReport(Array(body)).result
                    #expect(try value.objectValue?["error"]?.objectValue?["code"]?.numberValue?.integer(as:Int.self,limits:.balanced) == -32020)
                }
            }
        }
    }

    @Test func nativeHTTPVersionMismatchPrecedesUnsupportedVersionAndKeepsD01() async throws {
        try await withHTTP(httpCore()) { address,_ in
            let unsupported = Data(String(decoding:rpcHTTP(),as:UTF8.self).replacingOccurrences(of:"2026-07-28",with:"2025-11-25").utf8)
            let result = try await curlHTTP(address,data:unsupported)
            #expect(try result.status == 400 && codeHTTP(result) == -32020)
            let invalid = try await curlHTTP(address,data:Data(#"{"jsonrpc":"2.0","id":null,"method":"tools/list"}"#.utf8))
            #expect(try invalid.status == 400 && codeHTTP(invalid) == -32600)
            #expect(try JSONParser().parseWithReport(Array(invalid.body)).result.objectValue?["id"]?.isNull == true)
            for invalidID in ["null","true","1.5"] {
                let body = String(decoding:unsupported,as:UTF8.self).replacingOccurrences(of:"\"id\":1,",with:"\"id\":\(invalidID),")
                let genuine = try await curlHTTP(address,data:Data(body.utf8))
                #expect(try genuine.status == 400 && codeHTTP(genuine) == -32600)
                #expect(try JSONParser().parseWithReport(Array(genuine.body)).result.objectValue?["id"]?.isNull == true)
            }
        }
    }

    @Test func nativeHTTPSSEQuietStreamDisconnectCancelsSubscription() async throws {
        let core = try await httpCore()
        try await withHTTP(core,io:100) { address,_ in
            let socket = try HTTPTestSocket(address)
            try socket.request(rpcHTTP(method:"subscriptions/listen",params:#""notifications":{},"#),method:"subscriptions/listen")
            _ = try await socket.receive(until:"notifications/subscriptions/acknowledged")
            #expect(await core.activity.subscriptions == 1)
            socket.closeSocket()
            try await waitHTTP({ await core.activity.subscriptions == 0 },milliseconds:1000)
        }
    }

    @Test func nativeHTTPStalledWriterClosesAndReleasesTerminalOwnership() async throws {
        try await exerciseStalledHTTPWriter(.finite)
    }

    @Test func nativeHTTPStalledWriterCancelsLiveProviderAndRecovers() async throws {
        try await exerciseStalledHTTPWriter(.untilCancellation)
    }

    @Test func nativeHTTPConnectionCeilingRejectsOvershootAndRecovers() async throws {
        try await withHTTP(httpCore(),io:5000,connections:1) { address,transport in
            let first = try HTTPTestSocket(address); defer { first.closeSocket() }
            try await waitHTTP { await transport.activity.connections == 1 }
            let rejected = try HTTPTestSocket(address); defer { rejected.closeSocket() }
            #expect(try await rejected.receive().isEmpty)
            #expect(await transport.activity.connections == 1)
            first.closeSocket()
            try await waitHTTP { await transport.activity.connections == 0 }
            let admitted = try await curlHTTP(address,data:rpcHTTP())
            #expect(admitted.status == 200)
        }
    }

    @Test func nativeHTTPJSONSchema202012ValidatesInputAndOutputOnRealListener() async throws {
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object","properties":{"flag":{"const":true},"value":{"type":"string"}},"dependentRequired":{"flag":["value"]}},"outputSchema":{"type":"object","required":["answer"],"properties":{"answer":{"const":42}}}}"#)) { _,_ in
            try parseHTTP(#"{"resultType":"complete","content":[],"structuredContent":{"answer":42}}"#)
        }
        try await withHTTP(httpCore(tools:[tool])) { address,_ in
            let bad = try await curlHTTP(address,data:rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{"flag":true},"#),headers:["Mcp-Method: tools/call","Mcp-Name: wait"])
            #expect(try bad.status == 400 && codeHTTP(bad) == -32602)
            let valid = try await curlHTTP(address,data:rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{"flag":true,"value":"ok"},"#),headers:["Mcp-Method: tools/call","Mcp-Name: wait"])
            #expect(valid.status == 200)
            let value = try JSONParser().parseWithReport(Array(valid.body)).result
            #expect(try value.objectValue?["result"]?.objectValue?["structuredContent"]?.objectValue?["answer"]?.numberValue?.integer(as:Int.self,limits:.balanced) == 42)
        }
    }

    @Test func nativeHTTPParentTaskCancellationJoinsProviderAndSocket() async throws {
        let entered = HTTPCallCounter(),cancelled = HTTPCallCounter()
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
            entered.increment()
            do { try await Task.sleep(for:.seconds(60)) } catch { cancelled.increment(); throw error }
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        let core = try await httpCore(tools:[tool])
        let transport = try HTTPTransport(server:core,configuration:.init(authority:AuthorityPolicy(authorities:["localhost"],origins:[]),security:.loopbackDevelopment(anonymousHTTP)))
        let ready = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy:.bufferingNewest(1))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { do { try await transport.run { ready.continuation.yield($0) } } catch is CancellationError {} }
            var iterator = ready.stream.makeAsyncIterator(); let address = try #require(await iterator.next())
            let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
            socket.constrainReceiveWindow()
            try socket.request(rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),method:"tools/call")
            try await waitHTTP { entered.count == 1 }
            group.cancelAll(); try await group.waitForAll()
            #expect(cancelled.count == 1)
            _ = try await socket.receive()
        }
        let activity = await core.activity
        #expect(activity.active == 0 && activity.bufferedBytes == 0 && activity.requests == 0)
    }

    @Test func nativeHTTPBindFailurePreservesExistingListener() async throws {
        let core = try await httpCore()
        try await withHTTP(core) { address,_ in
            let duplicate = try HTTPTransport(server:core,configuration:.init(port:address.port,authority:AuthorityPolicy(authorities:["localhost"],origins:[]),security:.loopbackDevelopment(anonymousHTTP)))
            await #expect(throws:(any Error).self) { try await duplicate.run { _ in Issue.record("Occupied port became ready") } }
            let valid = try await curlHTTP(address,data:rpcHTTP()); #expect(valid.status == 200)
        }
    }

    @Test func nativeHTTPShutdownClosesOnlyOwnedSubscriptionsOnSharedCore() async throws {
        let core = try await httpCore()
        func transport() throws -> HTTPTransport {
            try HTTPTransport(server:core,configuration:.init(authority:AuthorityPolicy(authorities:["localhost"],origins:[]),security:.loopbackDevelopment(anonymousHTTP),ioMilliseconds:1000,drainMilliseconds:100))
        }
        let a = try transport(),b = try transport()
        let readyA = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy:.bufferingNewest(1))
        let readyB = AsyncStream<HTTPTransport.Address>.makeStream(bufferingPolicy:.bufferingNewest(1))
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { try await runHTTP(a,ready:readyA.continuation) }
            group.addTask { try await runHTTP(b,ready:readyB.continuation) }
            defer { group.cancelAll() }
            var ia = readyA.stream.makeAsyncIterator(),ib = readyB.stream.makeAsyncIterator()
            let sa = try HTTPTestSocket(#require(await ia.next())),sb = try HTTPTestSocket(#require(await ib.next()))
            defer { sa.closeSocket(); sb.closeSocket() }
            try sa.request(rpcHTTP(method:"subscriptions/listen",id:1,params:#""notifications":{"toolsListChanged":true},"#),method:"subscriptions/listen")
            try sb.request(rpcHTTP(method:"subscriptions/listen",id:2,params:#""notifications":{"toolsListChanged":true},"#),method:"subscriptions/listen")
            _ = try await sa.receive(until:"notifications/subscriptions/acknowledged")
            _ = try await sb.receive(until:"notifications/subscriptions/acknowledged")
            #expect(await core.activity.subscriptions == 2)
            await a.shutdown()
            try await waitHTTP { await core.activity.subscriptions == 1 }
            try await core.publish(.toolsChanged,audience:.requiringScopes([]))
            let continuing = try await sb.receive(until:"notifications/tools/list_changed")
            #expect(String(decoding:continuing,as:UTF8.self).contains("notifications/tools/list_changed"))
            let complete = try await sa.receive()
            #expect(String(decoding:complete,as:UTF8.self).contains("\"resultType\":\"complete\""))
            await b.shutdown(); try await group.waitForAll()
        }
        #expect(await core.activity.subscriptions == 0)
    }

    @Test func nativeHTTPHeaderDeadlineDoesNotExpireAnActiveResponse() async throws {
        let tool = ToolRegistration(definition:try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
            try await Task.sleep(for:.milliseconds(300))
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        try await withHTTP(httpCore(tools:[tool]),io:100) { address,_ in
            let partial = try HTTPTestSocket(address); defer { partial.closeSocket() }
            try partial.send(Data("POST /mcp HTTP/1.1\r\nHost:".utf8))
            #expect(try await partial.receive().isEmpty)
            let active = try await curlHTTP(address,data:rpcHTTP(method:"tools/call",params:#""name":"wait","arguments":{},"#),headers:["Mcp-Method: tools/call","Mcp-Name: wait"])
            #expect(active.status == 200 && String(decoding:active.body,as:UTF8.self).contains("\"resultType\":\"complete\""))
        }
    }
    @Test func nativeTLSVerifierDeadlineCancelsAndRedactsOperationalFailure() async throws {
        let entered = HTTPCallCounter(),cancelled = HTTPCallCounter()
        let security = try await httpSecurity(verifier:HTTPAwaitingVerifier(entered:entered,cancelled:cancelled))
        try await withHTTP(httpCore(),security:security,io:100) { address,_ in
            let result = try await curlHTTP(address,data:rpcHTTP(),headers:["Authorization: Bearer sentinel-secret"])
            #expect(result.status == 503 && result.body.isEmpty && entered.count == 1 && cancelled.count == 1)
            #expect(!result.headers.contains("sentinel-secret") && !result.headers.contains("invalid_token"))
        }
    }
    @Test func nativeTLSShutdownCancelsPendingVerifierAndJoinsConnection() async throws {
        let entered = HTTPCallCounter(),cancelled = HTTPCallCounter()
        let security = try await httpSecurity(verifier:HTTPAwaitingVerifier(entered:entered,cancelled:cancelled))
        try await withHTTP(httpCore(),security:security,io:5000) { address,transport in
            async let pending = curlHTTP(address,data:rpcHTTP(),headers:["Authorization: Bearer sentinel-secret"])
            try await waitHTTP { entered.count == 1 }
            let started = ContinuousClock.now
            await transport.shutdown()
            let result = try await pending
            #expect(cancelled.count == 1 && result.status != 200 && result.status != 401)
            #expect(ContinuousClock.now < started.advanced(by:.seconds(2)))
            #expect(!String(decoding:result.body,as:UTF8.self).contains("sentinel-secret"))
        }
    }


    @Test func nativeHTTPBufferedPipelineDoesNotSignalPeerClosure() async throws {
        for padding in [0, 1, 4096] {
            let entered = HTTPCallCounter(), cancelled = HTTPCallCounter()
            let release = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            defer { release.continuation.finish() }
            let tool = ToolRegistration(definition: try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
                entered.increment()
                if entered.count == 1 {
                    var iterator = release.stream.makeAsyncIterator()
                    _ = await iterator.next()
                    if Task.isCancelled { cancelled.increment(); throw CancellationError() }
                }
                return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
            }
            try await withHTTP(httpCore(tools: [tool])) { address,transport in
                let socket = try HTTPTestSocket(address); defer { socket.closeSocket() }
                do {
                    try socket.request(rpcHTTP(method: "tools/call", params: #""name":"wait","arguments":{},"#), method: "tools/call")
                    try await waitHTTP { entered.count == 1 }
                    // Ordinary unread pipelined data must not look like EV_EOF.
                    let arguments = "\"name\":\"wait\",\"arguments\":{\"padding\":\"" + String(repeating: "x", count: padding) + "\"},"
                    try socket.request(rpcHTTP(method: "tools/call", id: 2, params: arguments), method: "tools/call", close: true)
                    try await Task.sleep(for: .milliseconds(50))
                    #expect(entered.count == 1 && cancelled.count == 0)
                    release.continuation.yield(())
                    let response = String(decoding: try await socket.receive(), as: UTF8.self)
                    #expect(response.contains("\"id\":1") && response.contains("\"id\":2"))
                    #expect(response.components(separatedBy: "\"resultType\":\"complete\"").count == 3)
                    #expect(entered.count == 2 && cancelled.count == 0)
                } catch { release.continuation.finish(); await transport.shutdown(); throw error }
            }
        }
    }

    @Test func nativeHTTPRepeatedFINReleasesOwnersAndRecovers() async throws {
        await withKnownIssue(macOSEarlyEOFKnownIssue) {
        let entered = HTTPCallCounter(), cancelled = HTTPCallCounter()
        let tool = ToolRegistration(definition: try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
            entered.increment()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.increment(); throw error }
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        let core = try await httpCore(tools: [tool])
        try await withHTTP(core, connections: 1) { address,transport in
            do {
                for expected in 1...8 {
                    let socket = try HTTPTestSocket(address)
                    try socket.request(rpcHTTP(method: "tools/call", id: expected, params: #""name":"wait","arguments":{},"#), method: "tools/call")
                    try await waitHTTP { entered.count == expected }
                    socket.closeSocket() // Normal FIN; no linger/RST or speculative response head.
                    try await waitHTTP({ cancelled.count == expected }, milliseconds: 1000)
                    try await waitHTTP {
                        let state = await core.activity
                        return state.active == 0 && state.queued == 0 && state.requests == 0 && state.bufferedBytes == 0
                    }
                    let next = try await curlHTTP(address, data: rpcHTTP())
                    #expect(next.exit == 0 && next.status == 200)
                }
                #expect(entered.count == 8 && cancelled.count == 8)
            } catch { await transport.shutdown(); throw error }
        }
        }
    }

    @Test func nativeTLSPeerProcessExitCancelsBeforeResponseHead() async throws {
        await withKnownIssue(macOSEarlyEOFKnownIssue) {
        let entered = HTTPCallCounter(), cancelled = HTTPCallCounter()
        let tool = ToolRegistration(definition: try parseHTTP(#"{"name":"wait","inputSchema":{"type":"object"}}"#)) { _,_ in
            entered.increment()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.increment(); throw error }
            return try parseHTTP(#"{"resultType":"complete","content":[]}"#)
        }
        let security = try await httpSecurity()
        try await withHTTP(httpCore(tools: [tool]), security: security, mode: .sse) { address,transport in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-tls-peer-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = directory.appendingPathComponent("input")
            let output = directory.appendingPathComponent("output")
            try rpcHTTP(method: "tools/call", params: #""name":"wait","arguments":{},"#).write(to: input)
            let client = Process()
            client.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            client.arguments = ["-sS", "--http1.1", "--max-time", "5", "--noproxy", "*",
                "--cacert", try httpResource("test-cert").path, "-o", output.path,
                "-H", "Host: localhost", "-H", "Content-Type: application/json", "-H", "Accept: application/json, text/event-stream",
                "-H", "MCP-Protocol-Version: 2026-07-28", "-H", "Mcp-Method: tools/call", "-H", "Mcp-Name: wait",
                "-H", "Authorization: Bearer good", "--data-binary", "@" + input.path,
                "https://127.0.0.1:\(address.port)/mcp"]
            client.standardOutput = FileHandle.nullDevice; client.standardError = FileHandle.nullDevice
            async let completion = ownedHTTPClientExit(client)
            do {
                try await waitHTTP { entered.count == 1 }
                #expect((try? Data(contentsOf: output))?.isEmpty ?? true)
                client.terminate() // Only this owned subprocess; TLS is already authenticated.
                let status = try await completion
                #expect(status != 0)
                try await waitHTTP({ cancelled.count == 1 }, milliseconds: 1000)
            } catch {
                if client.isRunning { client.terminate() }
                await transport.shutdown()
                _ = try? await completion
                throw error
            }
        }
        }
    }

}

private struct HTTPAwaitingVerifier:TokenVerifier {
    let entered:HTTPCallCounter,cancelled:HTTPCallCounter
    func verify(_ bearerToken:String,forResource resource:ScalarText) async throws -> VerifiedAccessToken {
        entered.increment()
        do { try await Task.sleep(for:.seconds(60)) } catch { cancelled.increment(); throw error }
        throw HTTPAdmission.Failure.malformed
    }
}

@concurrent private func ownedHTTPClientExit(_ process: Process) async throws -> Int32 {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
        process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}
