// SPDX-License-Identifier: Apache-2.0
import Foundation
import BasicContainers
import NIOHTTPServer
import NIOCore
import HTTPAPIs
import JSON
import MCPProtocol
import MCPServer

/// One-shot transport with a caller-owned run lifetime. Construction does not
/// create a concrete listener (D11). Shutdown joins accepted-channel handlers.
public actor HTTPTransport {
    public enum Security: Sendable {
        case loopbackDevelopment(VerifiedPrincipal)
        case protectedResource(any HTTPAccessPolicy, NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials)
    }
    public enum ResponseMode: Sendable { case json, sse }
    public struct Configuration: Sendable {
        public let host: String, port: Int, admission: HTTPAdmission, authority: AuthorityPolicy
        public let security: Security, responseMode: ResponseMode
        public let connections: Int, headerBytes: Int, headerCount: Int
        public let ioMilliseconds: Int64, drainMilliseconds: Int64
        public init(host: String = "127.0.0.1", port: Int = 0, admission: HTTPAdmission? = nil,
                    authority: AuthorityPolicy, security: Security, responseMode: ResponseMode = .json,
                    connections: Int = 128, headerBytes: Int = 32_768, headerCount: Int = 128,
                    ioMilliseconds: Int64 = 30_000, drainMilliseconds: Int64 = 10_000) throws {
            guard !host.isEmpty, host.utf8.count <= 1024, (0...65535).contains(port),
                  (1...1024).contains(connections), (1...65536).contains(headerBytes),
                  (1...256).contains(headerCount), (1...120_000).contains(ioMilliseconds),
                  (1...30_000).contains(drainMilliseconds) else { throw HTTPAdmission.Failure.invalidConfiguration }
            if case .loopbackDevelopment = security {
                guard host == "127.0.0.1" || host == "::1" else { throw HTTPAdmission.Failure.invalidConfiguration }
            }
            self.host = host; self.port = port; self.admission = try admission ?? HTTPAdmission()
            self.authority = authority; self.security = security; self.responseMode = responseMode
            self.connections = connections; self.headerBytes = headerBytes; self.headerCount = headerCount
            self.ioMilliseconds = ioMilliseconds; self.drainMilliseconds = drainMilliseconds
        }
    }
    public struct Address: Sendable { public let host: String; public let port: Int; public let tls: Bool }
    private enum Completion:Sendable { case listener, ready, stopped }
    private enum State { case idle, running, stopping, stopped }
    private var state = State.idle
    private let server: Server, configuration: Configuration
    private let stop: AsyncStream<Void>, signal: AsyncStream<Void>.Continuation
    private let requests = HTTPRequestOwners()
    public init(server: Server, configuration: Configuration) throws {
        guard configuration.admission.maximumBodyBytes <= server.configuration.messageBytes else { throw HTTPAdmission.Failure.invalidConfiguration }
        self.server = server; self.configuration = configuration
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1)); stop = pair.stream; signal = pair.continuation
    }
    public struct Activity:Sendable { public let connections:Int, requests:Int; public let writeTimeouts:UInt64 }
    public var activity:Activity { get async { await requests.activity } }
    public func shutdown() { if state == .running { state = .stopping; signal.yield(()); signal.finish() } }
    public func run(ready: @escaping @Sendable (Address) async throws -> Void) async throws {
        guard state == .idle else { throw CoreFailure.duplicate }
        state = .running
        defer { state = .stopped; signal.finish() }
        let tls: Bool, transportSecurity: NIOHTTPServerConfiguration.TransportSecurity
        switch configuration.security {
        case .loopbackDevelopment: tls = false; transportSecurity = .plaintext
        case .protectedResource(_, let credentials): tls = true; transportSecurity = .tls(credentials:credentials)
        }
        var nio = try NIOHTTPServerConfiguration(bindTarget:.hostAndPort(host:configuration.host,port:configuration.port),
            supportedHTTPVersions:[.http1_1], transportSecurity:transportSecurity)
        nio.maxConnections = configuration.connections
        nio.backpressureStrategy = .watermark(low:1,high:2)
        // The pinned H1 readHeader timer re-arms at request body end,
        // while that response may still be active. Its finite idle timer already
        // bounds initial/partial headers and pauses exactly at decoded head.
        // Body, active core deadline and writer watchdog have independent bounds.
        nio.connectionTimeouts = .init(idle:.milliseconds(configuration.ioMilliseconds),
            readHeader:nil,readBody:.milliseconds(configuration.ioMilliseconds))
        nio.gracefulShutdown = .init(maximumGracefulShutdownDuration:.milliseconds(configuration.drainMilliseconds))
        let listener = NIOHTTPServer(configuration:nio)
        let handler = MCPHTTPRequestHandler(server:server,configuration:configuration,owners:requests)
        try await withThrowingTaskGroup(of:Completion.self) { group in
            group.addTask { [configuration] in try await listener.serve(connectionHandler:MCPHTTPConnectionHandler(handler:handler,limit:configuration.connections)); return .listener }
            group.addTask { [requests] in
                let addresses = try await listener.listeningAddresses
                guard addresses.count == 1, let bound = addresses.first else { throw CoreFailure.invalidPolicy }
                try await requests.bind(bound)
                try await ready(.init(host:bound.host,port:bound.port,tls:tls))
                return .ready
            }
            group.addTask { [stop, requests, server, configuration] in
                for await _ in stop { break }
                await requests.stop(server:server)
                let deadline = ContinuousClock.now.advanced(by:.milliseconds(configuration.drainMilliseconds))
                while await requests.count > 0 && ContinuousClock.now < deadline {
                    try await Task.sleep(for:.milliseconds(10))
                }
                return .stopped
            }
            defer { group.cancelAll() }
            while let result = try await group.next() { if result != .ready { break } }
        }
    }
}

private actor HTTPRequestOwners {
    struct Identity: Sendable { let principal:VerifiedPrincipal, origin:ScalarText }
    private var channels:Set<UUID> = []
    private var writeTimeouts:UInt64 = 0
    var activity:HTTPTransport.Activity { .init(connections:channels.count,requests:active.count,writeTimeouts:writeTimeouts) }
    func writerTimedOut() { if writeTimeouts < UInt64.max { writeTimeouts += 1 } }
    // Admission is a nonthrowing reservation. The caller must consume the
    // noncopyable NIOHTTPServer.Connection even when admission is refused.
    // NIO's maxConnections backs up accept(), but does not immediately reject
    // already accepted sockets: preserve the strict public connection ceiling.
    func connect(limit:Int) -> UUID? {
        guard !Task.isCancelled, !stopped, channels.count < limit else { return nil }
        let token = UUID(); channels.insert(token); return token
    }
    func disconnect(_ token:UUID) { channels.remove(token) }
    private var active: [UUID:Identity] = [:]
    private var correlations:[UUID:RequestCorrelation] = [:]
    private var stopped = false
    private var bound:NIOCore.SocketAddress?
    func bind(_ address:NIOHTTPServer.SocketAddress) throws { bound = try NIOCore.SocketAddress(ipAddress: address.host, port: address.port) }
    func isBound(_ local:NIOHTTPServer.SocketAddress) -> Bool {
        guard let bound, let endpoint = try? NIOCore.SocketAddress(ipAddress: local.host, port: local.port), bound.port == endpoint.port else { return false }
        return bound == endpoint || bound.ipAddress == "0.0.0.0" || bound.ipAddress == "::"
    }
    var count: Int { active.count }
    func insert(_ identity:Identity) throws -> UUID {
        guard !stopped else { throw CoreFailure.disconnected }
        let id = UUID(); active[id] = identity; return id
    }
    func attach(_ correlation:RequestCorrelation?,to id:UUID) { if let correlation { correlations[id] = correlation } }
    func remove(_ id:UUID) { active.removeValue(forKey:id); correlations.removeValue(forKey:id) }
    func stop(server:Server) async {
        stopped = true
        for correlation in correlations.values { await server.closeSubscription(correlation) }
    }
}

private struct MCPHTTPConnectionHandler:NIOHTTPServerConnectionHandler {
    let handler:MCPHTTPRequestHandler, limit:Int
    func handleConnection(connection:consuming sending NIOHTTPServer.Connection,context:NIOHTTPServer.ConnectionContext) async throws {
        // Both paths must transfer the ~Copyable connection to swift-http-server
        // without throwing or dropping it in MCPHTTP. The upstream listener's
        // maxConnections is backpressure, not rejection of accepted sockets.
        guard let token = await handler.owners.connect(limit:limit) else {
            // Cancellation closes an idle connection without servicing requests.
            // The child waits on a gate so it cannot enter the upstream request
            // loop until cancellation is guaranteed, even on a busy executor.
            let gate = AsyncStream<Void>.makeStream(bufferingPolicy:.bufferingNewest(1))
            let rejected = Task {
                for await _ in gate.stream { break }
                do {
                    try await NIOHTTPServerDefaultConnectionHandler(handler:handler)
                        .handleConnection(connection:connection,context:context)
                } catch {
                    // Expected when closing the rejected, already-cancelled child.
                }
            }
            rejected.cancel()
            gate.continuation.finish()
            await rejected.value
            return
        }
        // Keep the noncopyable Connection's internal destruction in swift-http-server.
        do {
            try await NIOHTTPServerDefaultConnectionHandler(handler:handler)
                .handleConnection(connection:connection,context:context)
        } catch {
            await handler.owners.disconnect(token)
            throw error
        }
        await handler.owners.disconnect(token)
    }
}
private struct HTTPConnectionComplete:Error {}

private struct MCPHTTPRequestHandler: HTTPServerRequestHandler {
    let server:Server, configuration:HTTPTransport.Configuration, owners:HTTPRequestOwners
    func handle(request:HTTPRequest, requestContext:consuming NIOHTTPServer.RequestContext,
                reader:consuming sending NIOHTTPServer.Reader,
                responseSender:consuming sending NIOHTTPServer.ResponseSender) async throws {
        var sender = Optional(responseSender)
        var reader = Optional(reader)
        do {
            guard request.headerFields.count <= configuration.headerCount,
                  (request.authority?.utf8.count ?? 0) <= 1024, (request.path?.utf8.count ?? 0) <= 8192 else { throw HeaderFailure.tooLarge }
            let headers = try HeaderFields(request.headerFields.map { .init($0.name.rawName,$0.value) },
                maximumCount:configuration.headerCount,maximumBytes:configuration.headerBytes,allowObsoleteText:true)
            guard !request.headerFields.contains(where:{ $0.name.rawName.lowercased() == "host" }), let host = request.authority, let local = requestContext.localAddress else {
                throw AuthorityPolicy.Failure.forbidden
            }
            guard await owners.isBound(local) else { throw AuthorityPolicy.Failure.forbidden }
            // No forwarded header changes either the peer, local bind, Host or Origin.
            let requestOrigin:String?
            do { requestOrigin = try headers.uniqueValue("Origin") } catch { throw AuthorityPolicy.Failure.forbidden }
            try configuration.authority.validate(authority:host,origin:requestOrigin,boundPort:local.port)
            if case .protectedResource(let access, _) = configuration.security,
               request.method == .get, let response = access.metadata(path:request.path ?? "") {
                try await response.send(sender.take()!); return
            }
            try configuration.admission.validate(method:request.method.rawValue,path:request.path ?? "",headers:headers)
            let principal:VerifiedPrincipal
            switch configuration.security {
            case .loopbackDevelopment(let anonymous):
                // Credentials are not silently ignored in an anonymous endpoint.
                guard try headers.uniqueValue("Authorization") == nil else { throw AuthorityPolicy.Failure.forbidden }
                principal = anonymous
            case .protectedResource(let access, _): principal = try await authenticate(access,headers:headers)
            }
            let origin = ScalarText(host.lowercased() + "|" + (try headers.uniqueValue("Origin") ?? ""))
            let owner = try await owners.insert(.init(principal:principal,origin:origin))
            do {
                let bytes = try await HTTPRequestReader.collect(reader.take()!,maximumBytes:configuration.admission.maximumBodyBytes)
                // HTTP core defines no client notifications. Reject without invoking
                // stdio cancellation/control behavior or making a JSON-RPC attempt.
                let ingress = try await server.inspectIngress(bytes,principal:principal,origin:origin,acceptNotifications:false,responseCopyMultiplier:4,responseFixedWork:UInt64(min(server.configuration.deadlineMilliseconds,configuration.ioMilliseconds) / 10 + 258))
                switch ingress {
                case .notification:
                    try await HTTPStaticResponse(status:400).send(sender.take()!)
                case .request(let ticket):
                    await owners.attach(ticket.correlation,to:owner)
                    let mailbox = HTTPResponseMailbox(maximumBytes:server.configuration.resultBytes)
                    let envelopeValidation:RequestEnvelopeValidator = { raw,budget in
                        try await budget.consume(UInt64(bytes.count) * 2 + UInt64(headers.logicalBytes) * 4 + UInt64(server.configuration.deadlineMilliseconds / 10 + 2) * 2 + 256)
                        guard let object = raw.objectValue, object["jsonrpc"]?.stringValue == "2.0", let requestID = object["id"],(try? RequestID(requestID)) != nil,
                              object["result"] == nil, object["error"] == nil,
                              let method = object["method"]?.stringValue,
                              let params = object["params"]?.objectValue,
                              let version = params["_meta"]?.objectValue?[ProtocolMetadata.protocolVersion]?.stringValue else { return }
                        let name = HeaderFields.mirroredNameField(for:method).flatMap { params[$0]?.stringValue }
                        do { try headers.validateMirrors(version:version,method:method,name:name) }
                        catch { throw RequestMirrorFailure.mismatch }
                    }
                    let validation:RequestIngressValidator = { request,budget in
                        try await budget.consume(UInt64(headers.logicalBytes) * 2 + 256)
                        if case .protectedResource(let access, _) = configuration.security {
                            if let method = WireMethod(rawValue:request.method.description) {
                                let name = method.mirroredNameField.flatMap { request.params[$0]?.stringValue }.map(ScalarText.init)
                                try access.authorize(principal,method:method,name:name)
                            } else { try access.authorizeSupplemental(principal, method: request.method) }
                        }
                    }
                    let scopes:RequestScopeValidator = { required,budget in
                        try await budget.consume(UInt64(required.reduce(0) { $0 + $1.description.utf8.count + 1 }) * 4 + 64)
                        if case .protectedResource(let access, _) = configuration.security {
                            try access.authorize(principal,requiredScopes:required)
                        }
                    }
                    let mirror:RequestMirrorValidator = { declarations,arguments,budget in
                        let value:JSON
                        switch arguments { case .value(let v):value = v; default:value = .null }
                        do { try await ToolHeaderMapping(declarations).validate(arguments:value,headers:headers,budget:budget) }
                        catch let error as HeaderFailure where error != .tooLarge && error != .invalidLimit { throw RequestMirrorFailure.mismatch }
                    }
                    let headerMethod = try? headers.value("Mcp-Method")
                    let streaming = configuration.responseMode == .sse || headerMethod == WireMethod.listen.rawValue
                    async let producer:Void = produce(server:server,ticket:ticket,mailbox:mailbox,streaming:streaming,validate:validation,validateEnvelope:envelopeValidation,validateScopes:scopes,mirror:mirror)
                    async let cancelled:Void = monitor(mailbox)
                    do {
                        if let first = try await mailbox.next() {
                            var head = HTTPResponse(status:.init(code:first.status))
                            head.headerFields[.contentType] = streaming && first.status == 200 ? "text/event-stream" : "application/json"
                            head.headerFields[.cacheControl] = "no-store"
                            if streaming && first.status == 200 { head.headerFields[HTTPField.Name("X-Accel-Buffering")!] = "no" }
                            let writer = try await sender.take()!.send(head)
                            let outputWriter = HTTPStreamWriter(writer)
                            async let output:Void = outputWriter.write(first:first,streaming:streaming && first.status == 200,mailbox:mailbox,maximumBytes:server.configuration.resultBytes,ioMilliseconds:configuration.ioMilliseconds,maximumTicks:Int(server.configuration.deadlineMilliseconds / 10 + 2))
                            try await mailbox.waitForCompletion()
                            try await output
                        }
                        try await producer
                        mailbox.cancel(); await cancelled
                    } catch {
                        await mailbox.fail(); mailbox.cancel()
                        throw error
                    }
                }
            } catch { await owners.remove(owner); throw error }
            await owners.remove(owner)
            if try headers.value("Connection")?.split(separator:",").contains(where:{ $0.trimmingCharacters(in:.whitespaces).lowercased() == "close" }) == true { throw HTTPConnectionComplete() }
        } catch {
            // Once a head is sent, failure aborts the exchange. Never send a second head.
            guard let responseSender = sender.take() else { throw error }
            let response:HTTPStaticResponse
            if let rejection = error as? HTTPAccessFailure { response = rejection.response }
            else if error is AuthorityPolicy.Failure { response = try .init(status:403) }
            else if let rejection = error as? HTTPAdmission.Failure {
                response = try .init(status:rejection.statusCode,fields:rejection == .methodNotAllowed ? [.init("Allow","POST")] : [])
            } else if error is HeaderFailure { response = try .init(status:400) }
            else { throw error }
            // A rejection before the body was read leaves it on the connection, so the
            // connection cannot carry another request. Say so instead of letting a client
            // reuse it and fail ("other side closed"), then end it deliberately.
            let unread = reader != nil
            try await response.send(responseSender, closing:unread)
            if unread { throw HTTPConnectionComplete() }
        }
    }
    private func authenticate(_ access:any HTTPAccessPolicy,headers:HeaderFields) async throws -> VerifiedPrincipal {
        try await withThrowingTaskGroup(of:VerifiedPrincipal.self) { group in
            group.addTask { try await access.authenticate(headers:headers) }
            group.addTask {
                try await Task.sleep(for:.milliseconds(configuration.ioMilliseconds))
                // An unavailable verifier is not evidence of invalid credentials.
                throw HTTPAccessFailure(response:try .init(status:503))
            }
            defer { group.cancelAll() }
            guard let principal = try await group.next() else { throw CoreFailure.disconnected }
            return principal
        }
    }
    private func produce(server:Server,ticket:AdmittedIngress,mailbox:HTTPResponseMailbox,streaming:Bool,
                         validate:@escaping RequestIngressValidator,validateEnvelope:@escaping RequestEnvelopeValidator,validateScopes:@escaping RequestScopeValidator,mirror:@escaping RequestMirrorValidator) async throws {
        do { try await server.dispatchEvents(ticket,mode:streaming ? .http : nil,validate:validate,validateEnvelope:validateEnvelope,validateScopes:validateScopes,mirror:mirror,observeError:{ await mailbox.observeError($0) },diagnosticTransport:.http) { try await mailbox.send($0) } }
        catch { await mailbox.finish(); throw error }
        await mailbox.finish()
    }
    private func monitor(_ mailbox:HTTPResponseMailbox) async {
        await withTaskGroup(of:Void.self) { group in
            group.addTask { for await _ in mailbox.cancellation.stream { break } }
            group.addTask {
                let maximumTicks = Int(server.configuration.deadlineMilliseconds / 10 + 2)
                for _ in 0..<maximumTicks {
                    if await mailbox.isCompleted { return }
                    if await mailbox.writeOverdue(.milliseconds(configuration.ioMilliseconds)) { await owners.writerTimedOut(); await mailbox.fail(); return }
                    do { try await Task.sleep(for:.milliseconds(10)) } catch { return }
                }
                await mailbox.fail()
            }
            await group.next(); group.cancelAll()
        }
        if await !mailbox.isCompleted { await mailbox.fail() }
    }
}
