# Application-facing Swift SDK integration roadmap

**Status:** roadmap and architectural direction agreed 2026-11-25; implementation
and API admission pending. This is not an API freeze, release qualification,
or authorization to publish packages.

## Intent and scope

Preserve protocol-facing precision while offering native application-facing
ergonomics. Build on the existing Swift-JSON and MCP implementations rather than
a second runtime, schema engine, transport, OAuth stack or authorization server.

Reference baselines: HTTP main 2cbedd510b15f510c24373ea45ca4fc9cf754cbe,
H5.4 77b29cb1f577bad2c584a5fd037f5f61e3626db7; qualified Core
d892bd34add1ad067ae6f286bd74c824486d8c07; Swift-JSON published 1.9.0
f2a0d12da7028edfbcb0cb307f19a921a3a12d03 and prepared 1.10.0 main
c2e4aea7cf63bdf8236c22cc9ba0c6a3abeb5201. These are inspection anchors,
not a decision to change any pins. Read each owning repository's instructions
before implementing. Preserve its independent release and qualification process.

## P0 — Packaging decision: monorepo first for JSON

Preferred: an opt-in JSONFoundationModels library product and target within
Swift-JSON, depending only on JSON and JSONSchema (DSL integration through
public schema documents; add a DSL dependency only if justified). Use Apple
SDK FoundationModels, conditional imports and precise availability where
possible. Do not add framework imports to existing products or change their
public contracts. Current JSON package has 13 public products (12 libraries,
one executable), no external package dependencies, macOS 15/iOS 18 deployment
floors, Swift tools 6.4, Linux/WASI contracts. Preserve all these existing
contracts; the new product can have a narrower documented availability.

Alternative if the isolation proof fails: a separate Swift-JSON-FoundationModels
repository/package with the same product name. A nested independent manifest
may be useful for local experimentation, but ordinary URL-based SwiftPM
consumption addresses a package root, not an arbitrary nested directory.
Do not choose a distribution layout that requires consumers to clone manually.

JF1 must compare actual SwiftPM 6.4.2 resolution, target build/link graphs,
availability and independent consumers. A conditional target edge only
conditionalizes build/link, not necessarily package resolution (SE-0273).
Traits are a possible opt-in mechanism; enabling traits is graph-wide and
must not be assumed to prevent a package dependency from being resolved.
Do not require a trait if product selection suffices. Prove ordinary JSON
consumers have no new external pins, imports, framework linkage, deployment
floor, compiler requirement or CI regressions. Qualify existing full-package
build/test, macOS 15/iOS 18 consumer deployment builds, Linux ARM64, and the
existing WASI lanes. Document unsupported bridge builds clearly; an empty
conditional module is not evidence of a working bridge.

Apple announced the open-source FoundationModels core for Linux at WWDC26.
Locate and pin an actual supported distribution before enabling the Linux
bridge. Neither that announcement nor the utilities repository proves
availability, licensing or compatibility with our Linux toolchain. Apple
on-device and PCC model availability is independent from framework availability.
If a future external FoundationModels package would change the core resolver
graph or platform contract, isolate it in a separate package/repository unless
an actual consumer matrix proves otherwise. No core dependency changes now.

## Package ownership and direction

- Swift-JSON owns JSON, JSONSchema, the existing DSL and JSONFoundationModels
  if P0 passes; otherwise the bridge owns a separate independent package.
- Swift-MCP-FoundationModels (proposed separate repository/package;
  MCPFoundationModels product) depends on Core MCPClient/MCPServer and the JSON
  bridge. It must not depend on HTTP merely to invoke an MCP tool.
- Swift-MCP-AppleIntegration (proposed separate repository/package;
  MCPAppleAuthorization client product; possible separate platform-neutral
  identity-verification product if needed) consumes the HTTP authorization
  interfaces. AuthenticationServices and Security are opt-in Apple-side
  integrations; server-side identity verification can use REST/JWKS on Linux.
  Keep client UI and server responsibilities in separate targets/products.
- No dependency from any existing core product to an integration package.
  No new repository, package manifest, tag or version publication in this batch.
  Names are working names until the API and graph are admitted.

## JF — JSON / Foundation Models

| Batch | Deliverable / acceptance |
| --- | --- |
| JF1 | Public SDK API and SwiftPM compatibility spike. Record exact compiler/SDK, available symbols, Codable shape, macro expansions only through public generated APIs, and actual graph/isolation results. Decide P0 from evidence. |
| JF2 | Bidirectional JSON / GeneratedContent value conversion. Explicit finite limits, cancellation and diagnostics. Test exact numbers, Unicode scalar identity, object keys, arrays, absent vs null, nesting, non-JSON values and metadata such as generation IDs. Reject or explicitly report losses. |
| JF3 | GenerationSchema -> JSONSchemaDocument and canonical schema -> GenerationSchema using verified public Codable/dynamic schema APIs. Compile native schema first, preserve original schema, use versioned compatibility inspection; never assume arbitrary JSON Schema is representable. Test nested objects, arrays, enums, optional/null, references, numeric/string constraints and unsupported constructs. |
| JF4 | Native @Generable / @Guide ergonomics and JSONSchemaDSL interoperability. Prefer typed conveniences over new macros. Demonstrate a single Swift type providing schema, generated value and native validation; no redundant annotations or duplicate schema engine. |

Use the existing OpenAIJSONSchemaBridge/provider-profile design as a conceptual
precedent, not as a reason to reuse OpenAI-specific rules. GenerationSchema
Codable serialization and GeneratedContent conversion are documented but
native coder interoperability and guide equivalence must be proven. Define
exact / explicitly projected / unsupported outcomes; exact only by default,
no silent schema weakening, external network reference lookup or lossy numeric
coercion. Model guidance never replaces canonical validation before invocation.
No model execution is required to test deterministic schema/value conversion.
Actual model-generated output is a separate, opt-in smoke test.

## MF — Bidirectional native MCP tools

| Batch | Deliverable / acceptance |
| --- | --- |
| MF1 | MCP client -> Foundation Models Tool. Discover selected remote tools with bounded pagination and collision-safe names, explicit allowlist, original schema preservation, argument validation, structured/text/multimodal result mapping, cancellation and error handling. Demonstrate with public Client.callTool through one transport-independent adapter. |
| MF2 | Foundation Models Tool -> MCP ToolRegistration. Derive admitted parameter schema, decode GeneratedContent into the tool's Arguments, encode supported output, reuse Core dispatcher, required scopes/features and RequestContext. Explicit host registration only. Context-dependent tools need a context-aware closure/factory; never bypass caller authorization. |
| MF3 | Host-side sampling integration using ClientConfiguration.sampling, then optional prompts/resources context, skills and dynamic profiles. Separate mapping/consent, privacy, model selection, budgets and MRTR semantics. Do not advertise unsupported model capabilities or automatically execute server-supplied sampling tools. |
| MF4 | External public consumer and end-to-end demonstration: one native Swift Tool usable locally and remotely; a discovered MCP tool usable by a LanguageModelSession. Verify both directions deterministically without a live model, plus an opt-in real model smoke. Confirm stdio/HTTP neutrality and preserve final release qualification. |

Proposed names and snippets are not released API. Use aliases or qualified
names to avoid FoundationModels.Tool / MCPClient.Tool collisions. No automatic
publication of local app actions. Tool output mapping must distinguish
complete, application error, extension/task and unsupported content; do not
flatten everything to text or leak credentials.

## AI — Native Apple identity and authorization

| Batch | Deliverable / acceptance |
| --- | --- |
| AI1 | ASWebAuthenticationSession implementation of AuthorizationUserAgent, with host-provided presentation context, correct callback/cancellation ownership and no replacement of the existing OAuth state/PKCE/issuer checks. |
| AI2 | KeychainTokenStore implementing TokenStore: protected storage keyed by endpoint and explicit namespace, atomic logical save/load/delete, access policy, redacted errors and cancellation/race tests. No automatic trust-store or entitlement changes. |
| AI3 | Federated Sign in with Apple via a cooperating authorization server. Apple login authenticates user; the authorization server owns consent, identity mapping and resource-bound MCP scopes/tokens. Server adapter consumes ordinary resource access tokens using TokenVerifier and existing AuthorizationMiddleware. |
| AI4 | Optional direct native ASAuthorizationAppleIDProvider flow with explicit cooperating broker contract; secure nonce/state/transaction binding, identity-token signature/issuer/audience/expiry validation, code handling, replay/rotation/revocation tests. Broker issues a distinct MCP access token. Do not assume arbitrary MCP endpoints support this profile. |

Authentication is not authorization. Apple ID tokens and Apple access tokens
must never be accepted or forwarded as MCP resource access tokens. Do not map
Apple contact permissions to MCP scopes, embed private keys/client secrets in
native clients, disable TLS verification, trust unverified claims or silently
fall back to anonymous access. Preserve RFC 9728 discovery and existing
resource/issuer/scope enforcement, bearer redaction and token storage boundaries.
Prefer the standard web OAuth route first; direct native login is additional,
not a mandatory new MCP protocol or a universal drop-in. A real federated login
needs an explicitly configured identity/authorization service, Apple Developer
identifiers/entitlements/redirects and protected backend key handling.
Do not build a general authorization server or JWT cryptography engine for
this ergonomics track. Use qualified verification and existing host services.

## Release sequencing

H5.1–H5.4 implementation exists on the current HTTP H5 branch; native
DocC, strengthened referee and external consumer qualification remain pending.
H3 native link probe, H4 head/static write lifecycle and H6 immutable pairing
remain independent release gates. Do not merge them or launch CI from this
roadmap update.

Before H5.5: JF1 packaging/API evidence, minimal JF2/JF3 and MF1/MF2 public
API feasibility probes, and AI1/AI2 interface feasibility review with
TokenVerifier/identity boundary decision. Capture concrete gaps in existing
public Core/HTTP contracts; if a core change is necessary, make it additive,
reviewed in the owning repository, and requalify. No broad requirement to
finish every optional adapter before RC1. Full JF4/MF3/MF4/AI integration
qualification and native Apple login deployment can proceed on independent
versions. Any API gap that actually blocks an agreed core contract must be
resolved before freezing it. Keep H5.5 a separate decision, not a milestone
silently passed by this roadmap. Next concrete increment: JF1 only.

## Source references

- Apple WWDC26, What's new in Foundation Models, open-source announcement:
  https://developer.apple.com/videos/play/wwdc2026/241/
- Foundation Models public API:
  https://developer.apple.com/documentation/foundationmodels/
- Apple's utilities repo, language-model protocol skill (GenerationSchema Codable):
  https://github.com/apple/foundation-models-utilities/blob/6c5a04c917b244f5b312d50cff305a8d3316d818/skills/foundation-models-language-model-protocol/SKILL.md
- SwiftPM traits:
  https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/
- SE-0273 (build/link condition vs package resolution):
  https://github.com/swiftlang/swift-evolution/blob/main/proposals/0273-swiftpm-conditional-target-dependencies.md
- SwiftPM deployment floor:
  https://docs.swift.org/latest/documentation/packagedescription/supportedplatform/
- Apple authentication user agent and identity validation:
  https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession
  https://developer.apple.com/documentation/signinwithapple/verifying-a-user
- MCP authorization and current project interfaces remain authoritative;
  refer to the frozen specification and existing AuthorizationUserAgent,
  TokenStore, TokenVerifier, ClientConfiguration and ToolRegistration.

This document records an architectural roadmap, not implementation evidence.
