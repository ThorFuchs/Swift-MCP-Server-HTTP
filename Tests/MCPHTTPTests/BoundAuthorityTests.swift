// SPDX-License-Identifier: Apache-2.0
import Testing
import MCPHTTP

@Test func boundListenerAuthorityIsExplicitAndStillChecksOrigin() throws {
    let exact = try AuthorityPolicy(authorities: ["127.0.0.1"], origins: [])
    #expect(throws: AuthorityPolicy.Failure.forbidden) { try exact.validate(authority: "127.0.0.1:43123", origin: nil, boundPort: 43123) }
    let bound = try AuthorityPolicy(authorities: ["127.0.0.1", "localhost", "[::1]"], origins: ["https://allowed.example"], portPolicy: .boundListener)
    for host in ["127.0.0.1", "LOCALHOST", "[::1]"] { try bound.validate(authority: host + ":43123", origin: "https://allowed.example", boundPort: 43123) }
    #expect(throws: AuthorityPolicy.Failure.forbidden) { try bound.validate(authority: "localhost:43123", origin: "https://evil.example", boundPort: 43123) }
    #expect(throws: AuthorityPolicy.Failure.forbidden) { try bound.validate(authority: "localhost:43123", origin: nil) }
}
@Test(arguments: ["127.0.0.1:43124", "evil.example:43123", "localhost.:43123", "user@localhost:43123", "localhost:43123/", "localhost:43123?x=1", "localhost%3a43123", "localhost:0", "localhost:65536"])
func boundListenerAuthorityRejectsForeignAndMalformedEndpoints(_ authority: String) throws {
    let policy = try AuthorityPolicy(authorities: ["127.0.0.1", "localhost"], origins: [], portPolicy: .boundListener)
    #expect(throws: AuthorityPolicy.Failure.forbidden) { try policy.validate(authority: authority, origin: nil, boundPort: 43123) }
}

@Test func boundOriginPortRequiresIndependentExplicitConsent() throws {
    let exactOrigin = try AuthorityPolicy(authorities: ["127.0.0.1"], origins: ["http://127.0.0.1"], portPolicy: .boundListener)
    #expect(throws: AuthorityPolicy.Failure.forbidden) { try exactOrigin.validate(authority: "127.0.0.1:43123", origin: "http://127.0.0.1:43123", boundPort: 43123) }
    let optedIn = try AuthorityPolicy(authorities: ["127.0.0.1"], origins: ["http://127.0.0.1"], portPolicy: .boundListener, originPortPolicy: .boundListener)
    try optedIn.validate(authority: "127.0.0.1:43123", origin: "http://127.0.0.1:43123", boundPort: 43123)
    for origin in ["http://127.0.0.1:43124", "http://evil.example:43123", "https://127.0.0.1:43123", "http://127.0.0.1:43123/"] {
        #expect(throws: AuthorityPolicy.Failure.forbidden) { try optedIn.validate(authority: "127.0.0.1:43123", origin: origin, boundPort: 43123) }
    }
}
