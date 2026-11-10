// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import MCPHTTP

@Test func authorityOriginAndForwardedSpoofing() throws {
    let policy = try AuthorityPolicy(authorities: ["127.0.0.1:8080", "example.com:443"],
                                     origins: ["https://example.com"])
    try policy.validate(authority: "EXAMPLE.com:443", origin: "https://EXAMPLE.com")
    try policy.validate(authority: "127.0.0.1:8080", origin: nil)
    for authority in ["example.com.evil:443", "example.com.:443", "example.com:443@evil.com",
                      "example.com:443 ", "evil.com", "example.com:80", "example.com%2e:443"] {
        #expect(throws: AuthorityPolicy.Failure.forbidden) { try policy.validate(authority: authority, origin: nil) }
    }
    for origin in ["null", "http://example.com", "https://example.com/", "https://example.com.evil",
                   "https://example.com@evil.com", "https://example.com/path"] {
        #expect(throws: AuthorityPolicy.Failure.forbidden) {
            try policy.validate(authority: "example.com:443", origin: origin)
        }
    }
    let spoofed = try HeaderFields([.init("Host", "evil.com"), .init("X-Forwarded-Host", "example.com:443")])
    #expect(throws: AuthorityPolicy.Failure.forbidden) {
        try policy.validate(authority: spoofed.uniqueValue("Host")!, origin: nil)
    }
}

@Test func modernHTTPAdmissionHasNoGETOrDELETE() throws {
    let admission = try HTTPAdmission(maximumBodyBytes: 4)
    let valid = try HeaderFields([.init("Content-Type", "application/json; charset=utf-8"),
                                 .init("Accept", "application/json, text/event-stream; q=0.5"),
                                 .init("Content-Length", "4")])
    try admission.validate(method: "POST", path: "/mcp", headers: valid)
    for method in ["GET", "DELETE", "post"] {
        #expect(throws: HTTPAdmission.Failure.methodNotAllowed) {
            try admission.validate(method: method, path: "/mcp", headers: valid)
        }
    }
    #expect(throws: HTTPAdmission.Failure.notFound) {
        try admission.validate(method: "POST", path: "/other", headers: valid)
    }
    let oversized = try HeaderFields([.init("Content-Type", "application/json"),
        .init("Accept", "application/json, text/event-stream"), .init("Content-Length", "5")])
    #expect(throws: HTTPAdmission.Failure.tooLarge) {
        try admission.validate(method: "POST", path: "/mcp", headers: oversized)
    }
}

@Test(arguments: ["application/json", "*/*", "application/json, text/event-stream;q=0",
                  "application/json;q=0, text/event-stream"])
func unacceptableMedia(_ accept: String) throws {
    let admission = try HTTPAdmission()
    let fields = try HeaderFields([.init("Content-Type", "application/json"), .init("Accept", accept)])
    #expect(throws: HTTPAdmission.Failure.notAcceptable) {
        try admission.validate(method: "POST", path: "/mcp", headers: fields)
    }
}

@Test(arguments: ["application/json, text/event-stream;q=1.1", "application/json, text/event-stream;q=0.0001",
                  "application/json, text/event-stream;q=0.2;q=0.5", "application/json,"])
func malformedMedia(_ accept: String) throws {
    let fields = try HeaderFields([.init("Content-Type", "application/json"), .init("Accept", accept)])
    #expect(throws: HTTPAdmission.Failure.malformed) {
        try HTTPAdmission().validate(method: "POST", path: "/mcp", headers: fields)
    }
}

@Test(arguments: ["", "Hello, 世界", " padded ", "line1\nline2", "=?base64?literal?=",
                  "\u{e9}", "e\u{301}", "\u{0}", "inside\ttab"])
func strictHeaderMirrorRoundTrip(_ value: String) throws {
    let encoded = try HeaderMirror.encode(value)
    #expect(try HeaderMirror.decode(encoded).utf8.elementsEqual(value.utf8))
}

@Test(arguments: ["=?base64?Zh==?=", "=?base64?Zg=?=", "=?base64?_w==?=",
                  "=?base64?/w==?=", "=?base64? Zg==?=", " padded ", "世界", "a\r\nb"])
func invalidMirrorEncodings(_ value: String) {
    #expect(throws: HeaderFailure.invalidValue) { _ = try HeaderMirror.decode(value) }
}

@Test func mirrorBoundsBeforeDecoding() throws {
    #expect(throws: HeaderFailure.tooLarge) {
        _ = try HeaderMirror.decode("=?base64?YWJjZA==?=", maximumDecodedBytes: 1)
    }
    #expect(try HeaderMirror.decode("=?base64?YQ==?=", maximumDecodedBytes: 1) == "a")
    #expect(throws: HeaderFailure.tooLarge) { _ = try HeaderMirror.encode("ab", maximumDecodedBytes: 1) }
    #expect(throws: HeaderFailure.tooLarge) { _ = try HeaderFields([.init("Foo", "x")], maximumBytes: 7) }
}

@Test func headersAreCaseInsensitiveValuesScalarExact() throws {
    let fields = try HeaderFields([.init("MCP-PROTOCOL-VERSION", "2026-07-28"),
        .init("Mcp-Method", "tools/call"), .init("mcp-name", HeaderMirror.encode("é"))])
    try fields.validateMirrors(version: "2026-07-28", method: "tools/call", name: "é")
    #expect(throws: HeaderFailure.mismatch) {
        try fields.validateMirrors(version: "2026-07-28", method: "tools/call", name: "e\u{301}")
    }
    let duplicate = try HeaderFields([.init("Mcp-Name", "a"), .init("mcp-name", "b")])
    #expect(throws: HeaderFailure.duplicate) { _ = try duplicate.value("MCP-NAME") }
    let identical = try HeaderFields([.init("A", "x"), .init("a", "x")])
    #expect(try identical.value("a") == "x")
    #expect(throws: HeaderFailure.invalidName) { _ = try HeaderFields([.init("bad name", "x")]) }
    #expect(throws: HeaderFailure.invalidValue) { _ = try HeaderFields([.init("name", "x\ny")]) }
}

@Test func missingAndMismatchedStandardHeaders() throws {
    let fields = try HeaderFields([.init("MCP-Protocol-Version", "2026-07-28"), .init("Mcp-Method", "resources/read")])
    #expect(throws: HeaderFailure.missing) {
        try fields.validateMirrors(version: "2026-07-28", method: "resources/read", name: "file:///x")
    }
    #expect(throws: HeaderFailure.mismatch) {
        try fields.validateMirrors(version: "2026-07-28", method: "prompts/get", name: "x")
    }
}

@Test func sseFramingHasNoReplayAndRejectsInjection() throws {
    #expect(try SSEFrame.message(Array("{}".utf8)) == Array("data: {}\n\n".utf8))
    #expect(throws: SSEFrame.Failure.tooLarge) { _ = try SSEFrame.message([1], maximumBytes: 8) }
    #expect(throws: SSEFrame.Failure.invalidPayload) { _ = try SSEFrame.message([0xff]) }
    #expect(throws: SSEFrame.Failure.invalidPayload) { _ = try SSEFrame.message(Array("{}\nid: 1".utf8)) }
    #expect(throws: SSEFrame.Failure.invalidPayload) { _ = try SSEFrame.message([13]) }
}
