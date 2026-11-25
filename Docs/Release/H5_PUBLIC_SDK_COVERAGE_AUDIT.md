# H5.2 — Public SDK and conformance coverage audit

Status: source and historical-evidence review, with a new client gate
implemented. Native execution of this candidate, DocC generation, external
consumer qualification and final API freeze remain open. Not an RC GO.

Base: integrated H1/H2 `2cbedd510b15f510c24373ea45ca4fc9cf754cbe`.
H5.1 baseline `80bfa680197daf5a28a9a09b9e450e8641f673f1`.
No Swift API, dependency manifest, lock, CI route, protocol reference or
referee version changes in this batch.

## Required coverage is a set, not a count

Canonical source: [Core 2026-07-28 frozen requirements](https://github.com/ThorFuchs/Swift-MCP-Server/blob/d892bd34add1ad067ae6f286bd74c824486d8c07/Reference/Conformance/requirements/2026-07-28.yaml),
Git blob `b0c4f8560429e8f4b6c89833cc0b35405bc004ff`. The anchor is
0.2.0-alpha.10; HTTP's package and npm lock select 0.2.0-alpha.12. Do not
modify the frozen file or promote later scenarios into its denominator.

| Client category | Selected | H1 CI Debug | H1 CI Release |
| --- | ---: | ---: | ---: |
| Frozen required (25 OAuth + 7 other) | 32 | 32/32 | 32/32 |
| Added-after-release JSON Schema preservation | 1 | 1/1 | 1/1 |
| Skills (SEP-2640, force-run extension) | 4 | 4/4 | 4/4 |
| Unsupported optional OAuth A6 | 0 of 6 | not run | not run |
| Selected total | 37 | 37/37 | 37/37 |

The old script's selection equals the frozen client set plus these five
supplements: no missing, extra-unclassified or duplicate selected names.
Both [Debug](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45604079743/job/139170335142)
and [Release](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45604079743/job/139170334821)
logs contain every selected name, 399 successful checks, zero failed and
zero warnings. The previous H1 native raw archive review records two
SKIPPED client checks per mode; these are not successful checks.
These CI logs were produced by the old script, not the new gate.

The six unsupported optional scenarios are client-credentials-jwt/basic,
enterprise-managed-authorization, dpop, dpop-nonce, and wif-jwt-bearer
(all auth/). A6 is explicitly excluded, not silently skipped required scope.
The additional JSON Schema scenario is distinct from the required
json-schema-ref-no-deref. Skills scenarios are supplemental implementation
gates, not frozen required tests.

## New client gate

`Scripts/client-conformance.sh` retains the pinned npm referee, selected
fixture configuration, existing timeout behavior and all 37 scenarios.
Build with forced resolved versions. After build, the Python gate obtains
the frozen reference from the actual fixture Core checkout, verifies the
checkout HEAD against both committed/resolved Core pins, and verifies the
frozen file Git blob. The required scenario names come from that file,
not a hardcoded count. The parser is deliberately narrow and hash-gated
(no general YAML interpreter and no new package dependency). Supplements
and unsupported scope are explicitly classified. The required execution
order now follows the frozen list; the four Skills retain --force.

Use a new output directory. Each scenario runs as a separate referee
invocation; validate its exit status, start and overall markers, exactly
one raw checks.json, known statuses, positive SUCCESS count, no FAILURE
or WARNING, and agreement with the referee summary. Preserve SKIPPED and
INFO in the JSON results. Do not override the referee's allowed client
error policy. plan.json and summary.json distinguish category counts;
verify the Core reference/checkout again after execution. This does not
attest the other 28 checkout HEADs; retain full graph qualification.

Python syntax and 12 offline unit tests passed in the editing environment.
Published gate and test Git blobs match the tested copies. The offline
tests use synthetic reference and raw-check fixtures, not a Swift build
or the actual npm referee. The complete real reference selection was
independently compared against the prior script and CI logs. Native
end-to-end execution is still required.

## Separate server gate gap

The canonical server set has 37 names. H1 CI reported 37/37 required,
13/13 implemented extensions, and three non-scored scenarios in both modes.
Existing conformance_summary.py determines scored names from returned
directories and the printed Not scored block, not the canonical set. It
does not require exact presence of all 37 names, can overwrite duplicate
scenario receipts, does not reject unknown statuses, and can count an
empty gated extension receipt as passed. The referee exit code is printed
but not itself used as a failure predicate. The historical summary is
therefore not independent exact-set verification. Some non-scored failures
may be intentional, so do not blindly require zero aggregate exit without
examining the referee's contract.

H5.3: enforce the exact frozen server set, unique receipts, explicit
non-scored policy and positive executed checks. Review the documented
tasks-status-notifications skip separately: never convert SKIPPED into
SUCCESS or invent a successful notification test. Preserve warning and
pending semantics transparently. Do not edit the reference or bypass the
official referee. H5.2 did not change the server gate. H5.3 subsequently
implemented the independent exact-set validator and replayed the H1 native
archive; see [H5.3 Server Conformance Gate](H5_SERVER_CONFORMANCE_GATE.md).
The historical 13/13 extension count is now explicitly separated into
12 executed passing scenarios and one known upstream skipped scenario.

## Public SDK surface (source review, not a symbol-graph ABI inventory)

| Product | Host-facing contract | Existing evidence and remaining work |
| --- | --- | --- |
| MCPHTTP | HTTPTransport, Configuration, Security, Activity; AuthorityPolicy, HTTPAdmission, HTTPAccessPolicy, HTTPStaticResponse and header mapping | Native JSON/SSE, authority, TLS, ownership/connection ceiling and Core integration; #25 head/static deadline remains open. |
| MCPHTTPAuthorization | TokenVerifier, VerifiedAccessToken, AuthorizationMiddleware, HTTPAuthorizationPolicy, ProtectedResourceMetadata, ScopePolicy, BearerChallenge | Native synthetic TLS/verifier and policy tests. Host owns crypto/credentials; not an OAuth authorization server. |
| MCPHTTPClient | HTTPClientTransport (Core ClientTransport), HTTPClientAuthorizing, HTTPAuthorizationChallenge, HTTPClientTransportError | Real loopback JSON/SSE Tools, mirrored parameters, progress, MRTR and listen; challenge retry tests and referee. Host owns injected AsyncHTTPClient and its policy. |
| MCPClientAuthorization | OAuthClient, OAuthClientConfiguration, identity/registration types, AuthorizationUserAgent, AuthorizationRequest, TokenStore, StoredAuthorization, InMemoryTokenStore, OAuthClientError | A1–A5 tests (PKCE, issuer/resource, scope/refresh, migration, persisted state and collision regression); A6 not implemented. |

All four now have DocC landing catalogs (H5.1). Build public symbol graphs
and convert all four with warnings-as-errors before accepting a final API
inventory or freezing the public symbols. API review must include public
dependency types in signatures (Core, NIOHTTPServer TLS, AsyncHTTPClient,
NIO TimeAmount, JSON); do not claim independent platform compatibility
from a Swift library compile alone.

### Security / contract review queue

- HTTPTransport caller owns run; shutdown signals stopping, completion
  of run establishes joined lifetime. Preserve H4's separate head/static
  write deadline acceptance; do not imply all write phases are qualified.
- HTTPClientTransport accepts host endpoint, client and additional
  headers. Document HTTPS and trusted host configuration; test conflicting
  reserved headers and cancellation/deadline behavior before API freeze.
- OAuthClient's discovery URL rules validate requested URLs, while the
  actual AsyncHTTPClient exchange delegates redirect behavior. Its
  authorizationHeaders can restore credentials for the configured endpoint;
  inspect insecure endpoint restoration, cross-origin and downgrade
  redirects with synthetic tests and decide an explicit host/library
  contract. Do not claim these are observed exploits or that the SDK
  enforces every redirected URL. The challenge's sentAuthorization and
  StoredAuthorization contain secrets. Inspect signOut versus an in-flight
  authorization/refresh and cancelled waiters as separate race tests.
- SECURITY.md now links the actual Core docs and states host boundaries.
  Do not print bearer tokens, token-store contents or real credentials.

## Packaging, platform and consumer gates

- Root and conformance fixture declare Swift tools 6.4, macOS 27.0, and
  Swift-JSON minimum 1.9.0. The old issue #14 root minimum statement is
  obsolete; example manifest still says 1.8.0, effectively raised by the
  SDK graph. Align the example with the final release graph under H6.
- Root/fixture 29-pin graph is currently locked, but their manifests
  still declare mutable Core branch main; H6 is the release contract
  change. Official swift-http-server dependency selection is H3, not
  solved by this audit.
- macOS ARM64 is the qualified runtime profile; Linux ARM64 compile/link
  only. No HTTP iOS, older macOS, AMD64 or Linux runtime claim.
- The existing example README referred to a removed consumer script and
  local NIO vendor candidate; updated to the real local-package build.
  The example is not yet a fresh external SwiftPM consumer and still has
  the raw HTTP-server/Core main dependency declarations. No new example
  build claimed.
- Fixtures exercise both products against official mock/reference peers;
  existing loopback interop test covers Tools/MRTR/progress/listen. Add
  external consumer smoke importing all four products, true SDK-to-SDK
  TLS/OAuth protected flow, Resources/Prompts/Tasks/Skills and the cross-
  transport matrix where required (Core session owns stdio). Do not
  mistake separate referee legs for every SDK-to-SDK combination.
- LICENSE/NOTICE and fixture upstream license exist; audit all actual
  transitive licenses/SBOM for the final graph. Root has no CHANGELOG
  file in this revision; prepare it only with actual accepted release
  scope. No tag or GitHub Release authorized.

## Disposition

H5.2 source audit and client gate implementation complete, pending native
qualification. H5.3 server gate is implemented; API/consumer negative
controls and fresh native qualification remain next.
H3/H4/H6 remain independent. No main change, merge, tag or release.
