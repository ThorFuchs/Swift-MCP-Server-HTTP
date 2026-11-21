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
private let issuer2 = "https://auth2.example"

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
    var duplicateRedirectKey: String? = nil
    var redirectFragment = false
    var cimdSupported = false
    var authMethods = ["none"]
    var registrationMethod: String? = nil
    var registrationSecret: String? = nil
    var tokenType = "Bearer"
    var authorizationDelay: Duration = .zero
    var serverScopes: [String]? = nil
    var refreshToken: String? = nil
    var refreshFails = false
    var expiresIn = 3600
    /// Overrides the published token endpoint of the first authorization server.
    var tokenEndpoint: String? = nil
}

/// A request log shared by the fake servers and the user agent.
private final class Log: Sendable {
    struct Entry: Sendable { let method: String; let url: String; let headers: [String: String]; let body: String }
    private let entries = Mutex<[Entry]>([])
    private let authorizations = Mutex<[URLComponents]>([])
    private let server = Mutex(issuer)
    /// The authorization server the protected resource metadata names; tests move it.
    var authorizationServer: String { get { server.withLock { $0 } } set { server.withLock { $0 = newValue } } }
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
            return json(200, #"{"resource":"\#(behavior.prmResource)","authorization_servers":["\#(log.authorizationServer)"]\#(scopes)}"#)
        case ("GET", "https://auth2.example/.well-known/oauth-authorization-server"):
            return json(200, #"{"issuer":"\#(issuer2)","authorization_endpoint":"\#(issuer2)/authorize","token_endpoint":"\#(issuer2)/token","registration_endpoint":"\#(issuer2)/register","response_types_supported":["code"],"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"]}"#)
        case ("POST", "\(issuer2)/register"):
            return json(201, #"{"client_id":"second-client"}"#)
        case ("POST", "\(issuer2)/token"):
            let number = log.requests(to: "/token").count
            return json(200, #"{"access_token":"token-\#(number)","token_type":"Bearer","expires_in":3600,"refresh_token":"r2"}"#)
        case ("GET", "https://auth.example/.well-known/oauth-authorization-server/tenant"):
            return json(200, """
                {"issuer":"\(behavior.metadataIssuer)","authorization_endpoint":"\(issuer)/authorize?tenant=1",
                 "token_endpoint":"\(behavior.tokenEndpoint ?? "\(issuer)/token")","registration_endpoint":"\(issuer)/register",
                 "response_types_supported":["code"],"code_challenge_methods_supported":["S256"],
                 "token_endpoint_auth_methods_supported":\(list(behavior.authMethods)),
                 "authorization_response_iss_parameter_supported":\(behavior.issSupported),
                 "client_id_metadata_document_supported":\(behavior.cimdSupported)\(behavior.serverScopes.map { ",\"scopes_supported\":" + list($0) } ?? "")}
                """)
        case ("POST", "\(issuer)/register"):
            let secret = behavior.registrationSecret.map { #","client_secret":"\#($0)""# } ?? ""
            let method = behavior.registrationMethod.map { #","token_endpoint_auth_method":"\#($0)""# } ?? ""
            return json(201, #"{"client_id":"registered-client"\#(secret)\#(method)}"#)
        case ("POST", "\(issuer)/token"):
            let grant = form(text)["grant_type"]
            if grant == "refresh_token", behavior.refreshFails { return json(400, #"{"error":"invalid_grant"}"#) }
            // Access tokens are numbered by token request; only the code grant issues a refresh token.
            let refresh = grant == "authorization_code" ? behavior.refreshToken.map { #","refresh_token":"\#($0)""# } ?? "" : ""
            let number = log.requests(to: "/token").count
            return json(200, #"{"access_token":"token-\#(number)","token_type":"\#(behavior.tokenType)","expires_in":\#(behavior.expiresIn)\#(refresh)}"#)
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
        if let duplicate = behavior.duplicateRedirectKey,
           let original = items.first(where: { $0.name == duplicate }) {
            items.append(original)
        }
        response.queryItems = items
        if behavior.redirectFragment { response.fragment = "unexpected" }
        return response.url!
    }
}

private func oauth(_ behavior: Behavior = Behavior(), identity: ClientIdentity? = nil, log: Log, store: (any TokenStore)? = nil,
                   configure: (inout OAuthClientConfiguration) -> Void = { _ in }) -> OAuthClient {
    var configuration = OAuthClientConfiguration(
        identity: identity ?? ClientIdentity(dynamicRegistration: DynamicRegistration(clientName: "tests")), redirectURI: redirect)
    configure(&configuration)
    return OAuthClient(endpoint: endpoint, configuration: configuration,
        userAgent: ApprovingUserAgent(behavior: behavior, log: log), tokenStore: store, http: FakeServers(behavior: behavior, log: log))
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

    // Issue #10: the development loopback exception covers only real loopback literals.
    @Test(arguments: [
        "http://127.0.0.1", "http://127.0.0.1:8976/callback", "http://127.0.0.2", "http://127.255.255.255/x", "http://127.0.0.0",
        "http://localhost", "http://LOCALHOST:9000/a", "http://[::1]", "http://[::1]:8080/mcp",
    ])
    func developmentLoopbackAcceptsLoopbackLiterals(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(URLRules.isAllowed(url, insecureLoopback: true))
        #expect(!URLRules.isAllowed(url, insecureLoopback: false))
    }

    @Test(arguments: [
        // DNS names that only look like loopback literals.
        "http://127.attacker.example", "http://127.attacker.example/token", "http://127.0.0.1.attacker.example",
        "http://127.0.0.1.evil", "http://127.0.0.1.nip.io", "http://127.0.0.1-evil.example", "http://localhost.evil",
        "http://localhost.evil.example", "http://evil-localhost", "http://my.localhost.example", "http://127.example.127",
        // Malformed or non-canonical IPv4.
        "http://127.1", "http://127.0.1", "http://127.0.0", "http://127.0.0.1.1", "http://127.0.0.256", "http://127.0.0.-1",
        "http://127..0.1", "http://127.0.0.", "http://127.000.0.1", "http://127.0.0.01", "http://0177.0.0.1", "http://0x7f.0.0.1",
        "http://2130706433",
        // Not loopback at all.
        "http://128.0.0.1", "http://126.255.255.255", "http://10.0.0.1", "http://0.0.0.0", "http://auth.example", "http://[::2]",
        "http://[::]",
        // Loopback, but with a fragment.
        "http://127.0.0.1/x#f", "http://localhost/#",
    ])
    func developmentLoopbackRejectsEverythingElse(url: String) throws {
        let url = try #require(URL(string: url))
        #expect(!URLRules.isAllowed(url, insecureLoopback: true))
        #expect(!URLRules.isAllowed(url, insecureLoopback: false))
    }

    @Test func httpsPolicyIsUnchangedByTheLoopbackRules() throws {
        for text in ["https://127.attacker.example/token", "https://auth.example", "https://127.0.0.1:8443", "https://localhost"] {
            let url = try #require(URL(string: text))
            #expect(URLRules.isAllowed(url, insecureLoopback: false) && URLRules.isAllowed(url, insecureLoopback: true))
        }
        #expect(!URLRules.isAllowed(try #require(URL(string: "https://auth.example/#f")), insecureLoopback: true))
        #expect(!URLRules.isAllowed(try #require(URL(string: "ftp://127.0.0.1")), insecureLoopback: true))
    }

    @Test(arguments: ["http://127.attacker.example/tenant", "http://127.0.0.1.attacker.example/tenant"])
    func aLookalikeLoopbackIssuerIsNeverContacted(server: String) async throws {
        let log = Log()
        log.authorizationServer = server
        await #expect(throws: OAuthClientError.insecureURL(server)) {
            _ = try await oauth(log: log) { $0.allowsInsecureLoopback = true }.handleChallenge(challenge())
        }
        #expect(log.all.map(\.url) == ["https://mcp.example/.well-known/oauth-protected-resource/mcp"])
        #expect(log.authorizationRequests.isEmpty)
    }

    @Test func aLookalikeLoopbackTokenEndpointReceivesNoCodeOrRegistration() async throws {
        let log = Log()
        let token = "http://127.attacker.example/token"
        await #expect(throws: OAuthClientError.insecureURL(token)) {
            _ = try await oauth(Behavior(tokenEndpoint: token), log: log) { $0.allowsInsecureLoopback = true }.handleChallenge(challenge())
        }
        #expect(log.requests(to: "/register").isEmpty && log.requests(to: "/token").isEmpty && log.authorizationRequests.isEmpty)
        #expect(!log.all.contains { $0.url.contains("attacker") })
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

private func insufficient(_ scope: String, sent: String) -> HTTPAuthorizationChallenge {
    HTTPAuthorizationChallenge(endpoint: endpoint, status: 403,
        wwwAuthenticate: [#"Bearer error="insufficient_scope", scope="\#(scope)", resource_metadata="https://mcp.example/.well-known/oauth-protected-resource/mcp""#],
        sentAuthorization: sent)
}

@Suite struct OAuthClientScopesAndRefresh {
    @Test func stepUpAsksForTheUnionOfScopesAndOfflineAccess() async throws {
        let log = Log()
        let client = oauth(Behavior(serverScopes: ["mcp:read", "mcp:write", "offline_access"]), log: log)
        #expect(try await client.handleChallenge(challenge(#"Bearer error="invalid_token", scope="mcp:read""#)))
        #expect(try await client.handleChallenge(insufficient("mcp:write", sent: "Bearer token-1")))
        #expect(log.authorizationRequests.map { query($0)["scope"] } == ["mcp:read offline_access", "mcp:read offline_access mcp:write"])
        #expect(try await client.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-2"])
        // Scopes the token was already requested with cannot be fixed by asking again.
        #expect(try await !client.handleChallenge(insufficient("mcp:read", sent: "Bearer token-2")))
        #expect(log.authorizationRequests.count == 2)
    }

    @Test func offlineAccessOnlyWhenOfferedAndWanted() async throws {
        let unlisted = Log()
        _ = try await oauth(Behavior(serverScopes: ["mcp:read"]), log: unlisted).handleChallenge(challenge(#"Bearer scope="mcp:read""#))
        #expect(query(try #require(unlisted.authorizationRequests.first))["scope"] == "mcp:read")
        let declined = Log()
        _ = try await oauth(Behavior(serverScopes: ["mcp:read", "offline_access"]), log: declined) { $0.requestsOfflineAccess = false }
            .handleChallenge(challenge(#"Bearer scope="mcp:read""#))
        #expect(query(try #require(declined.authorizationRequests.first))["scope"] == "mcp:read")
    }

    @Test func stepUpsStopAtTheLimitAndNeedInsufficientScope() async throws {
        let log = Log()
        let client = oauth(log: log) { $0.maximumStepUps = 2 }
        #expect(try await client.handleChallenge(challenge(#"Bearer scope="a""#)))
        #expect(try await client.handleChallenge(insufficient("b", sent: "Bearer token-1")))
        #expect(try await client.handleChallenge(insufficient("c", sent: "Bearer token-2")))
        #expect(try await !client.handleChallenge(insufficient("d", sent: "Bearer token-3")))
        #expect(try await !client.handleChallenge(HTTPAuthorizationChallenge(endpoint: endpoint, status: 403,
            wwwAuthenticate: [#"Bearer error="invalid_token""#], sentAuthorization: "Bearer token-3")))
        #expect(log.authorizationRequests.count == 3)
        // A fresh 401 authorization resets the count.
        #expect(try await client.handleChallenge(challenge(#"Bearer scope="a""#, sent: "Bearer token-3")))
        #expect(try await client.handleChallenge(insufficient("e", sent: "Bearer token-4")))
    }

    @Test func aRejectedTokenIsRefreshedWithoutTheUser() async throws {
        let log = Log()
        let client = oauth(Behavior(refreshToken: "r1"), log: log)
        #expect(try await client.handleChallenge(challenge()))
        #expect(try await client.handleChallenge(challenge(sent: "Bearer token-1")))
        #expect(try await client.handleChallenge(challenge(sent: "Bearer token-2")))
        #expect(log.authorizationRequests.count == 1)
        let refreshes = log.requests(to: "/token").dropFirst().map { form($0.body) }
        // The refresh token is kept when the server does not rotate it.
        #expect(refreshes.map { $0["grant_type"] } == ["refresh_token", "refresh_token"] && refreshes.allSatisfy { $0["refresh_token"] == "r1" })
        #expect(refreshes.allSatisfy { $0["resource"] == "https://mcp.example/mcp" && $0["client_id"] == "registered-client" })
        #expect(try await client.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-3"])
    }

    @Test func aFailedRefreshFallsBackToAuthorization() async throws {
        let log = Log()
        let client = oauth(Behavior(refreshToken: "r1", refreshFails: true), log: log)
        #expect(try await client.handleChallenge(challenge()))
        #expect(try await client.handleChallenge(challenge(sent: "Bearer token-1")))
        #expect(log.authorizationRequests.count == 2)
        #expect(try await client.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-3"])
    }


    @Test(arguments: ["state", "code", "iss"])
    func duplicateOAuthRedirectKeysAreRejected(_ key: String) async throws {
        let log = Log()
        let client = oauth(Behavior(duplicateRedirectKey: key), log: log)
        await #expect(throws: OAuthClientError.self) {
            _ = try await client.handleChallenge(challenge())
        }
        #expect(log.requests(to: "/token").isEmpty)
    }

    @Test func fragmentInAuthorizationRedirectIsRejected() async throws {
        let log = Log()
        let client = oauth(Behavior(redirectFragment: true), log: log)
        await #expect(throws: OAuthClientError.self) {
            _ = try await client.handleChallenge(challenge())
        }
        #expect(log.requests(to: "/token").isEmpty)
    }

    @Test func proactiveRefreshPersistenceFailureIsSurfacedAndRecovers() async throws {
        actor FailingOnceStore: TokenStore {
            struct SaveFailure: Error {}
            private var saved: StoredAuthorization?
            private var shouldFail = false
            func load(endpoint: URL) async throws -> StoredAuthorization? { saved }
            func save(_ authorization: StoredAuthorization, endpoint: URL) async throws {
                if shouldFail {
                    shouldFail = false
                    throw SaveFailure()
                }
                saved = authorization
            }
            func delete(endpoint: URL) async throws { saved = nil }
            func failNextSave() { shouldFail = true }
        }

        let log = Log()
        let store = FailingOnceStore()
        let client = oauth(Behavior(refreshToken: "r1", expiresIn: 10), log: log, store: store)
        #expect(try await client.handleChallenge(challenge()))
        #expect(try await store.load(endpoint: endpoint)?.accessToken == "token-1")

        await store.failNextSave()
        await #expect(throws: FailingOnceStore.SaveFailure.self) {
            _ = try await client.authorizationHeaders(for: endpoint)
        }
        #expect(try await store.load(endpoint: endpoint)?.accessToken == "token-1")
        #expect(await client.isAuthorized)

        // The original refresh token and issuer remain usable after a failed
        // save; a subsequent refresh can persist a consistent new credential.
        #expect(try await client.authorizationHeaders(for: endpoint).map(\\.value) == ["Bearer token-3"])
        #expect(try await store.load(endpoint: endpoint)?.accessToken == "token-3")
        #expect(log.authorizationRequests.count == 1)
    }

    @Test func tokensAreRefreshedShortlyBeforeTheyExpire() async throws {
        let log = Log()
        // Expires within the refresh margin, so the next request refreshes first.
        let client = oauth(Behavior(refreshToken: "r1", expiresIn: 10), log: log)
        #expect(try await client.handleChallenge(challenge()))
        #expect(try await client.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-2"])
        #expect(log.authorizationRequests.count == 1)
        // Without a refresh token the expiring token is sent as is.
        let plain = oauth(Behavior(expiresIn: 10), log: Log())
        #expect(try await plain.handleChallenge(challenge()))
        #expect(try await plain.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-1"])
    }
}

@Suite struct OAuthClientLifecycle {
    @Test func aNewAuthorizationServerGetsItsOwnClientAndNoOldCredentials() async throws {
        let log = Log()
        let store = InMemoryTokenStore()
        let client = oauth(Behavior(refreshToken: "r1"), log: log, store: store)
        #expect(try await client.handleChallenge(challenge()))
        log.authorizationServer = issuer2
        #expect(try await client.handleChallenge(challenge(sent: "Bearer token-1")))
        #expect(try await client.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-2"])

        // No refresh at the old server, and nothing of the old client at the new one.
        #expect(log.requests(to: "/token").map(\.url) == ["\(issuer)/token", "\(issuer2)/token"])
        #expect(log.requests(to: "/register").map(\.url) == ["\(issuer)/register", "\(issuer2)/register"])
        let second = log.all.filter { $0.url.hasPrefix(issuer2) }
        #expect(!second.contains { $0.body.contains("registered-client") || $0.body.contains("r1") })
        #expect(query(try #require(log.authorizationRequests.last))["client_id"] == "second-client")
        let saved = try #require(await store.load(endpoint: endpoint))
        #expect(saved.issuer == issuer2 && saved.clientID == "second-client" && saved.accessToken == "token-2" && saved.refreshToken == "r2")
    }

    @Test func storedAuthorizationSurvivesARestart() async throws {
        let store = InMemoryTokenStore()
        let first = Log()
        #expect(try await oauth(Behavior(scopesSupported: ["mcp:read"], registrationSecret: "s", refreshToken: "r1"), log: first, store: store)
            .handleChallenge(challenge(#"Bearer error="invalid_token""#)))
        let saved = try #require(await store.load(endpoint: endpoint))
        #expect(saved.issuer == issuer && saved.resource == "https://mcp.example/mcp" && saved.clientID == "registered-client")
        #expect(saved.clientSecret == "s" && saved.authentication == .clientSecretBasic)
        #expect(saved.accessToken == "token-1" && saved.refreshToken == "r1" && saved.scopes == ["mcp:read"])
        #expect(try #require(saved.expiresAt).timeIntervalSinceNow > 3500)

        // A new process: the stored token is sent without any request, and a rejection is
        // answered by refreshing with the stored client instead of asking the user.
        let second = Log()
        let restarted = oauth(Behavior(registrationSecret: "s", refreshToken: "r1"), log: second, store: store)
        #expect(try await restarted.authorizationHeaders(for: endpoint).map(\.value) == ["Bearer token-1"])
        #expect(second.all.isEmpty)
        #expect(try await restarted.handleChallenge(challenge(sent: "Bearer token-1")))
        #expect(second.authorizationRequests.isEmpty && second.requests(to: "/register").isEmpty)
        let refresh = try #require(second.requests(to: "/token").first)
        #expect(form(refresh.body)["grant_type"] == "refresh_token" && refresh.headers["authorization"]?.hasPrefix("Basic ") == true)
        #expect(try await store.load(endpoint: endpoint)?.accessToken == "token-1")   // numbered per log: the refresh was the first token request

        try await restarted.signOut()
        #expect(try await store.load(endpoint: endpoint) == nil)
        #expect(try await restarted.authorizationHeaders(for: endpoint).isEmpty)
    }

    @Test func storeFailuresAreReported() async throws {
        struct Broken: TokenStore {
            struct Failure: Error {}
            func load(endpoint: URL) async throws -> StoredAuthorization? { throw Failure() }
            func save(_ authorization: StoredAuthorization, endpoint: URL) async throws { throw Failure() }
            func delete(endpoint: URL) async throws { throw Failure() }
        }
        await #expect(throws: Broken.Failure.self) { _ = try await oauth(log: Log(), store: Broken()).authorizationHeaders(for: endpoint) }
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
