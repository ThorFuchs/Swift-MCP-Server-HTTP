# H5.4 — External public SDK consumer

**Status:** consumer and runner implemented; native Swift 6.4.2 resolution,
compilation and execution pending. This is not a release GO.

Base H5.3: `cfd1945da35213406d3c54fb51dac21870e3fbe1`.
Integrated baseline: `2cbedd510b15f510c24373ea45ca4fc9cf754cbe`.
No changes to shipping Swift sources, dependencies, Core, reference bytes,
referee, workflow or platform floor.

## Independent consumption

The runner materializes `Tools/ExternalConsumer/Package.swift.in` and its
three Swift source files in a new workspace outside the SDK checkout. It
declares the HTTP package by its public Git URL and exact source revision,
not a path dependency, fork, vendored copy or internal test target. The
executable imports and exercises all four public HTTP products plus their
explicitly declared public dependency products (Core, JSON, NIOHTTPServer,
AsyncHTTPClient and NIOSSL). It never uses @testable or internal helpers.

The root and fixture locks must agree. The current 29-pin graph is preserved
and exactly one HTTP pin is added for the external consumer. Force resolved
versions and verify all 30 pin objects, actual checkout HEADs and cleanliness
after resolution, each build and each successful runtime. An unexpected
resolver graph is a failure to review, not permission to update dependencies
silently. Direct requirements are derived from the locked states, including
disabled HTTP-server traits. The Core main-branch requirement remains a
pre-release limitation; H6 must repeat the qualification against the approved
versioned pair. Do not infer compatibility with arbitrary version resolution.

## Native test matrix

Build one standalone executable in Debug and optimized Release using Swift
Build. Each binary runs separately in JSON and SSE response mode, with a
fresh synthetic issuer and token on loopback. Each process must emit the
following eight ordered successful checkpoints and its mode completion:

| Checkpoint | What is asserted |
| --- | --- |
| tls_metadata | Full TLS verification with an ephemeral CA; exact resource and advertised issuer |
| denials | Missing/invalid bearer 401, insufficient scope 403, zero tool provider effects |
| oauth_login | Protected discovery challenge, actual authorization code grant, PKCE S256, issuer/state validation through public OAuthClient, host TokenStore contains expected issuer/resource/client/token |
| tools_mirrors_progress | Tool listing, Unicode mirrored region, verified principal/resource inside provider, exact echo and one SSE progress event (zero in JSON) |
| resources | List and read actual synthetic greeting resource |
| prompts | List and retrieve actual synthetic prompt |
| restore_signout | New OAuthClient restores from host store without opening user agent; deletes state and no longer returns authorization headers |
| joined | Caller-owned listener run joined; all Core/HTTP activity counters zero and no write timeout |

The Python issuer is deliberately a small synthetic test peer, not an
authorization server product. It serves RFC 8414 metadata, accepts one
pre-registered public client's authorization request, returns a captured
302 redirect (never follows the callback URL), and checks code, PKCE hash,
client ID, scope, exact resource and redirect before issuing a random test
token. The host-supplied HTTPClient enables full certificate verification
and disables automatic redirects. Require exactly one metadata, one
authorization and one token request, zero rejected requests, and joined
issuer after each successful process. Test CA and leaf keys are generated
per qualification and removed with their temporary directory; no trust
store is modified. Only synthetic credentials are used; do not commit
runtime logs, certificates or keys.

The SDK listener needs a known port to publish the exact resource URI.
The runner selects an ephemeral loopback port before launching the process;
a bind collision fails the test rather than silently selecting another
resource. The issuer and SDK use separate loopback HTTPS endpoints.
120 seconds is an outer executable safety limit, not a widened SDK
timeout. Each HTTP exchange has a 5-second timeout.

## Verification already performed

- Python syntax and **8/8 offline test methods** passed locally.
- The Python test runs a real loopback HTTPS issuer using the generated
  CA and leaf, verifies the metadata and code grant, rejects an incorrect
  PKCE verifier and rejects a reused code. This proves the test peer's
  behavior, not the Swift OAuth client.
- The exact root/fixture lock JSONs from the earlier H1 native archive
  `http-h1-9l6enh_w.tar.gz` were successfully seeded to 30 pins.
- Native Swift compilation/typechecking, actual SwiftPM graph resolution,
  and the four-process consumer matrix are **not yet executed**. The
  editing environment has Linux Swift 6.2.1, not Apple Swift 6.4.2.
  No successful native consumer result is claimed.

## Native run

From a clean checkout of the exact H5.4 candidate SHA, on a quiet Mac with
macOS 27+, Swift 6.4.2, Xcode and Python/OpenSSL:

    python3 -I Scripts/test-external-consumer.py
    python3 -I Scripts/qualify-external-consumer.py "$(git rev-parse HEAD)" "$HOME/MCP-H5-Consumer"

Use an output parent on the external SSD if desired, outside the source
checkout. The runner requires a conservative minimum of 25 GiB free on
the consumer workspace volume; this is not a measured upper bound and
SwiftPM caches can still use the internal drive. Both build configurations
share one scratch directory. The runner retains the external worktree
and creates an archive of evidence only (manifest, lock/checkout receipts,
toolchain, logs, issuer counts, decision.json), including ordinary failure.
Return the archive for review. No hosted CI or artifact upload is required.

## Remaining scope

A successful H5.4 smoke does not replace H5.2/H5.3 native referee runs, DocC
or final full SDK qualification. It does not test untrusted-CA rejection,
interactive browser UI, real issuer deployments, refresh/step-up/migration,
concurrent sign-out, redirect attack handling, MRTR, subscriptions/listen,
Tasks/Skills, stdio or every public API in the external consumer. Existing
native/referee tests remain in place; these larger interop/security matrices
and the final symbol-graph/API inventory are separate acceptance gates.
H3 and H4 remain independent. Rerun on the final H6 immutable pair.
Do not merge, tag or close #14 solely on the basis of implementation or
offline host tests.
