// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
import JSON
@testable import MCPClientAuthorization
import MCPHTTPClient
import MCPProtocol
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

private let endpoint = URL(string: "https://mcp.example/mcp")!
private let issuer = "https://auth.example/tenant"
private let redirect = URL(string: "http://127.0.0.1:8976/callback")!

/// How the fake authorization and resource servers behave.
struct Behavior: Sendable {
    enum Iss: Sendable { case correct, omit, value(String) }
    var prmResource = "https://mcp.example/mcp"
    var scopesSupported: [String]? = nil
    var metadataIssuer = issuer
    var issSupported = true
    var iss = Iss.correct
    var tamperState = false
    var redirectError: String? = nil
    var cimdSupported = false
    var authMethods = ["none"]
    var registrationMethod: String? = nil
    var registrationSecret: String? = nil
    var tokenType = "Bearer"
    var authorizationDelay: Duration = .zero
}

/// A request log shared by the fake servers and the user agent.
private final class Log: Sendable {
    struct Entry: Sendable { let method: String; let url: String; let headers: [String: String]; let body: String }
    private let entries = Mutex<[Entry]>([])
    private let authorizations = Mutex<[URLComponents]>([])
    func append(_ entry: Entry) { entries.withLock { $0.append(entry) } }
    func authorized(_ url: URL) { authorizations.withLock { $0.append(URLComponents(url: url, resolvingAgainstBaseURL: false)!) } }
    var all: [Entry] { entries.withLock { $0 } }
    var authorizationRequests: [URLComponents] { authorizations.withLock { $0 } }
    func requests(to suffix: String) -> [Entry] { all.filter { $0.url.hasSuffix(suffix) } }
}

private func form(_ body: String) -> [String: String] {
    var values: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? "" }
        values[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return values
}

private func query(_ components: URLComponents) -> [String: String] {
    Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
}

private struct FakeServers: AuthorizationHTTP {
    let behavior: Behavior
    let log: Log

    func send(method: String, url: URL, headers: [(name: String, value: String)], body: [UInt8]?, maximumBytes: Int) async throws -> AuthorizationHTTPResponse {
        let text = String(decoding: body ?? [], as: UTF8.self)
        log.append(.init(method: method, url: url.absoluteString,
            headers: Dictionary(headers.map { ($0.name.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first }), body: text))
        func json(_ status: Int, _ document: String) -> AuthorizationHTTPResponse {
            AuthorizationHTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: Array(document.utf8))
        }
        func list(_ values: [String]) -> String { "[" + values.map { "\"\($0)\"" }.joined(separator: ",") + "]" }
        switch (method, url.absoluteString) {
        case ("GET", "https://mcp.example/.well-known/oauth-protected-resource/mcp"):
            let scopes = behavior.scopesSupported.map { #","scopes_supported":\#(list($0))"# } ?? ""
            return json(200, #"{"resource":"\#(behavior.prmResource)","authorization_servers":["\#(issuer)"]\#(scopes)}"#)
        case ("GET", "https://auth.example/.well-known/oauth-authorization-server/tenant"):
            return json(200, """
                {"issuer":"\(behavior.metadataIssuer)","authorization_endpoint":"\(issuer)/authorize?tenant=1",
                 "token_endpoint":"\(issuer)/token","registration_endpoint":"\(issuer)/register",
                 "response_types_supported":["code"],"code_challenge_methods_supported":["S256"],
                 "token_endpoint_auth_methods_supported":\(list(behavior.authMethods)),
                 "authorization_response_iss_parameter_supported":\(behavior.issSupported),
                 "client_id_metadata_document_supported":\(behavior.cimdSupported)}
                """)
        case ("POST", "\(issuer)/register"):
            let secret = behavior.registrationSecret.map { #","client_secret":"\#($0)""# } ?? ""
            let method = behavior.registrationMethod.map { #","token_endpoint_auth_method":"\#($0)""# } ?? ""
            return json(201, #"{"client_id":"registered-client"\#(secret)\#(method)}"#)
        case ("POST", "\(issuer)/token"):
            return json(200, #"{"access_token":"token-1","token_type":"\#(behavior.tokenType)","expires_in":3600}"#)
        default:
            return json(404, #"{"error":"not_found"}"#)
        }
    }
}

/// Answers like an authorization endpoint that approves at once.
private struct ApprovingUserAgent: AuthorizationUserAgent {
    let behavior: Behavior
    let log: Log
    func authorize(_ request: AuthorizationRequest) async throws -> URL {
        log.authorized(request.url)
        if behavior.authorizationDelay > .zero { try await Task.sleep(for: behavior.authorizationDelay) }
        let parameters = query(URLComponents(url: request.url, resolvingAgainstBaseURL: false)!)
        var response = URLComponents(url: request.redirectURI, resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let error = behavior.redirectError { items.append(.init(name: "error", value: error)) }
        else { items.append(.init(name: "code", value: "code-1")) }
        items.append(.init(name: "state", value: behavior.tamperState ? "forged" : parameters["state"]))
        switch behavior.iss {
        case .correct: items.append(.init(name: "iss", value: request.issuer))
        case .omit: break
        case .value(let value): items.append(.init(name: "iss", value: value))
        }
        response.queryItems = items
        return response.url!
    }
}

private func oauth(_ behavior: Behavior = Behavior(), identity: ClientIdentity? = nil, log: Log) -> OAuthClient {
    let configuration = OAuthClientConfiguration(
        identity: identity ?? ClientIdentity(dynamicRegistration: DynamicRegistration(clientName: "tests")), redirectURI: redirect)
    return OAuthClient(endpoint: endpoint, configuration: configuration,
        userAgent: ApprovingUserAgent(behavior: behavior, log: log), http: FakeServers(behavior: behavior, log: log))
}

private func challenge(_ header: String = #"Bearer error="invalid_token", scope="mcp:read mcp:write""#, sent: String? = nil) -> HTTPAuthorizationChallenge {
    HTTPAuthorizationChallenge(endpoint: endpoint, status: 401, wwwAuthenticate: [header], sentAuthorization: sent)
}

@Suite struct OAuthClientCodeFlow {
    @Test func authorizesWithPKCEResourceAndStateThenSendsBearer() async throws {
        let log = Log()
        let client = oauth(log: log)
        #expect(try await client.authorizationHeaders(for: endpoint).isEmpty)
        #expect(try await client.handleChallenge(challenge()))
        #expect(try await client.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-1"])

        // Discovery: the path-inserted PRM URL first, then the path-inserted RFC 8414 URL.
        #expect(log.all.prefix(2).map(\.url) == ["https://mcp.example/.well-known/oauth-protected-resource/mcp",
                                                 "https://auth.example/.well-known/oauth-authorization-server/tenant"])
        let registration = try #require(log.requests(to: "/register").first)
        let document = try WireCodec.parse(Array(registration.body.utf8), limits: .balanced).result.objectValue
        #expect(document?["application_type"]?.stringValue == "native")
        #expect(document?["redirect_uris"]?.arrayValue?.first?.stringValue == redirect.absoluteString)

        let authorization = try #require(log.authorizationRequests.first)
        let parameters = query(authorization)
        #expect(authorization.path == "/tenant/authorize" && parameters["tenant"] == "1")
        #expect(parameters["response_type"] == "code" && parameters["client_id"] == "registered-client")
        #expect(parameters["code_challenge_method"] == "S256" && parameters["resource"] == "https://mcp.example/mcp")
        #expect(parameters["scope"] == "mcp:read mcp:write" && parameters["redirect_uri"] == redirect.absoluteString)

        let token = form(try #require(log.requests(to: "/token").first).body)
        #expect(token["grant_type"] == "authorization_code" && token["code"] == "code-1")
        #expect(token["resource"] == parameters["resource"] && token["redirect_uri"] == redirect.absoluteString)
        let verifier = try #require(token["code_verifier"])
        #expect(Base64URL.encode(SHA256.hash(data: Array(verifier.utf8))) == parameters["code_challenge"])
        #expect(token["client_id"] == "registered-client" && token["client_secret"] == nil)
    }

    @Test(arguments: [
        (Behavior.Iss.value("https://evil.example.com"), true, OAuthClientError.issuerParameterMismatch(expected: issuer, actual: "https://evil.example.com")),
        (.value(issuer + "/"), true, .issuerParameterMismatch(expected: issuer, actual: issuer + "/")),
        (.value("https://evil.example.com"), false, .issuerParameterMismatch(expected: issuer, actual: "https://evil.example.com")),
        (.omit, true, .issuerParameterMissing),
    ])
    func rejectsAuthorizationResponsesBeforeTheCodeIsSent(iss: Behavior.Iss, advertised: Bool, expected: OAuthClientError) async throws {
        let log = Log()
        let client = oauth(Behavior(issSupported: advertised, iss: iss), log: log)
        await #expect(throws: expected) { _ = try await client.handleChallenge(challenge()) }
        #expect(log.requests(to: "/token").isEmpty)
        #expect(try await client.authorizationHeaders(for: endpoint).isEmpty)
    }

    @Test func acceptsAMissingIssWhenTheServerDoesNotAdvertiseIt() async throws {
        let log = Log()
        #expect(try await oauth(Behavior(issSupported: false, iss: .omit), log: log).handleChallenge(challenge()))
        #expect(log.requests(to: "/token").count == 1)
    }

    @Test func rejectsForgedStateAndDeniedAuthorization() async throws {
        let forged = Log()
        await #expect(throws: OAuthClientError.stateMismatch) { _ = try await oauth(Behavior(tamperState: true), log: forged).handleChallenge(challenge()) }
        #expect(forged.requests(to: "/token").isEmpty)
        let denied = Log()
        await #expect(throws: OAuthClientError.authorizationDenied(error: "access_denied", description: nil)) {
            _ = try await oauth(Behavior(redirectError: "access_denied"), log: denied).handleChallenge(challenge())
        }
    }

    @Test func rejectsTokensOtherThanBearer() async throws {
        await #expect(throws: OAuthClientError.unsupportedTokenType("DPoP")) {
            _ = try await oauth(Behavior(tokenType: "DPoP"), log: Log()).handleChallenge(challenge())
        }
    }

    @Test func concurrentChallengesShareOneAuthorization() async throws {
        let log = Log()
        let client = oauth(Behavior(authorizationDelay: .milliseconds(50)), log: log)
        async let first = client.handleChallenge(challenge())
        async let second = client.handleChallenge(challenge())
        #expect(try await [first, second] == [true, true])
        #expect(log.authorizationRequests.count == 1)
        // A request rejected with an older token retries with the current one without a new flow.
        #expect(try await client.handleChallenge(challenge(sent: "Bearer stale")))
        #expect(log.authorizationRequests.count == 1)
    }
}

@Suite struct OAuthClientDiscoveryAndIdentity {
    @Test func metadataWithAnotherIssuerIsNotUsed() async throws {
        let log = Log()
        await #expect(throws: OAuthClientError.issuerMismatch(expected: issuer, actual: "https://attacker.example.com")) {
            _ = try await oauth(Behavior(metadataIssuer: "https://attacker.example.com"), log: log).handleChallenge(challenge())
        }
        #expect(log.requests(to: "/register").isEmpty && log.authorizationRequests.isEmpty)
    }

    @Test func aResourceThatDoesNotCoverTheEndpointStopsDiscovery() async throws {
        let log = Log()
        await #expect(throws: OAuthClientError.resourceMismatch(resource: "https://evil.example.com/mcp", endpoint: endpoint.absoluteString)) {
            _ = try await oauth(Behavior(prmResource: "https://evil.example.com/mcp"), log: log).handleChallenge(challenge())
        }
        #expect(log.all.map(\.url) == ["https://mcp.example/.well-known/oauth-protected-resource/mcp"])
    }

    @Test(arguments: [
        ("https://mcp.example/mcp", true), ("https://mcp.example", true), ("https://MCP.example:443/", true),
        ("https://mcp.example/mc", false), ("https://mcp.example/mcp/v2", false), ("http://mcp.example/mcp", false),
        ("https://mcp.example:8443/mcp", false), ("https://evil.example.com/mcp", false), ("https://mcp.example/mcp?x=1", false),
    ])
    func resourceCoverage(resource: String, covers: Bool) {
        #expect(Discovery.resource(resource, covers: endpoint) == covers)
    }

    @Test func candidateURLsFollowRFC8414AndRFC9728() throws {
        let discovery = Discovery(http: FakeServers(behavior: Behavior(), log: Log()), insecureLoopback: false, maximumBytes: 1024)
        #expect(try discovery.serverCandidates("https://auth.example/tenant1").map(\.absoluteString) == [
            "https://auth.example/.well-known/oauth-authorization-server/tenant1",
            "https://auth.example/.well-known/openid-configuration/tenant1",
            "https://auth.example/tenant1/.well-known/openid-configuration"])
        #expect(try discovery.serverCandidates("https://auth.example").map(\.absoluteString) == [
            "https://auth.example/.well-known/oauth-authorization-server", "https://auth.example/.well-known/openid-configuration"])
        #expect(try discovery.resourceCandidates(endpoint, hint: nil).map(\.absoluteString) == [
            "https://mcp.example/.well-known/oauth-protected-resource/mcp", "https://mcp.example/.well-known/oauth-protected-resource"])
        #expect(try discovery.resourceCandidates(endpoint, hint: "https://mcp.example/custom.json").map(\.absoluteString) == ["https://mcp.example/custom.json"])
        // Plain http is refused unless development loopback is allowed, and then only for loopback.
        #expect(throws: OAuthClientError.insecureURL("http://auth.example")) { _ = try discovery.serverCandidates("http://auth.example") }
        let development = Discovery(http: FakeServers(behavior: Behavior(), log: Log()), insecureLoopback: true, maximumBytes: 1024)
        #expect(try development.serverCandidates("http://localhost:9000").count == 2)
        #expect(throws: OAuthClientError.insecureURL("http://auth.example")) { _ = try development.serverCandidates("http://auth.example") }
    }

    @Test func preRegisteredClientsAuthenticateWithFormEncodedBasicCredentials() async throws {
        let log = Log()
        let identity = ClientIdentity(preRegistered: [PreRegisteredClient(issuer: issuer, clientID: "a:b", clientSecret: "s/cret")])
        #expect(try await oauth(Behavior(authMethods: ["client_secret_basic"]), identity: identity, log: log).handleChallenge(challenge()))
        #expect(log.requests(to: "/register").isEmpty)
        let token = try #require(log.requests(to: "/token").first)
        #expect(token.headers["authorization"] == "Basic " + Data("a%3Ab:s%2Fcret".utf8).base64EncodedString())
        #expect(form(token.body)["client_secret"] == nil && form(token.body)["client_id"] == nil)
    }

    @Test func registeredClientsUseTheMethodTheServerAssigned() async throws {
        let log = Log()
        let behavior = Behavior(authMethods: ["client_secret_post"], registrationMethod: "client_secret_post", registrationSecret: "secret")
        #expect(try await oauth(behavior, log: log).handleChallenge(challenge()))
        let token = form(try #require(log.requests(to: "/token").first).body)
        #expect(token["client_id"] == "registered-client" && token["client_secret"] == "secret")
    }

    @Test func metadataDocumentsReplaceRegistrationWhenSupported() async throws {
        let log = Log()
        let document = URL(string: "https://client.example/metadata.json")!
        let identity = ClientIdentity(metadataDocument: document, dynamicRegistration: DynamicRegistration(clientName: "tests"))
        #expect(try await oauth(Behavior(cimdSupported: true), identity: identity, log: log).handleChallenge(challenge()))
        #expect(log.requests(to: "/register").isEmpty)
        #expect(query(try #require(log.authorizationRequests.first))["client_id"] == document.absoluteString)
        // Without support or registration there is no identity to use.
        await #expect(throws: OAuthClientError.noClientIdentity(issuer: issuer)) {
            _ = try await oauth(Behavior(), identity: ClientIdentity(metadataDocument: document), log: Log()).handleChallenge(challenge())
        }
    }

    @Test func scopeComesFromTheChallengeElseTheResourceElseIsOmitted() async throws {
        let listed = Log()
        _ = try await oauth(Behavior(scopesSupported: ["a", "b"]), log: listed).handleChallenge(challenge(#"Bearer error="invalid_token""#))
        #expect(query(try #require(listed.authorizationRequests.first))["scope"] == "a b")
        let none = Log()
        _ = try await oauth(log: none).handleChallenge(challenge(#"Bearer error="invalid_token""#))
        #expect(query(try #require(none.authorizationRequests.first))["scope"] == nil)
    }
}

@Suite struct WWWAuthenticateParsing {
    @Test func findsTheBearerChallengeAmongOthers() {
        let parameters = BearerChallenge.parameters([
            #"Basic realm="a, b", Bearer error="invalid_token", scope="x y", resource_metadata="https://m.example/.well-known/r", error_description="say \"hi\"""#])
        #expect(parameters?["scope"] == "x y" && parameters?["error"] == "invalid_token")
        #expect(parameters?["resource_metadata"] == "https://m.example/.well-known/r" && parameters?["error_description"] == #"say "hi""#)
        #expect(BearerChallenge.parameters([#"Basic realm="x""#]) == nil)
        #expect(BearerChallenge.parameters(["Bearer"]) == [:])
        #expect(BearerChallenge.parameters([#"DPoP algs="ES256", bearer Scope=a"#])?["scope"] == "a")
    }
}
