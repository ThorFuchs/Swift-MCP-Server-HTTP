# Swift-MCP-Server-HTTP — RC readiness and evidence ledger

**Snapshot:** 2026-11-23 · **Decision:** **NO-GO for 1.0.0 / public RC tag** until the blockers below are closed.  
**Qualified integration candidate:** `a4fad1c955f6cfc09d9939d5d2db2b96692b5d89` on branch `fix/oauth-issuer-isolation-structured-assertions`; [PR #24](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/pull/24) for code-review/CI integration.  
**Base at snapshot:** `main = 7287b61910e713b5790f57e111e8d9273f46996c` (PR #23 merged). **Do not confuse an integration candidate with an authorized release.**

This ledger is an auditable release decision **as of the snapshot**; update gate status with *new exact-commit evidence* rather than replacing failed historical results. Use [the response lifecycle contract](../HTTP_RESPONSE_LIFECYCLE.md), [host-run runbook](../HTTP_LIFECYCLE_RUNBOOK.md), [the previous qualification baseline](../RELEASE_QUALIFICATION.md) and [CI diagnostic #22](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/22) for details.

## 1. What is actually qualified

### Reproducible final Studio FULL run — OAuth integration candidate

- **Archive:** `studio-full-a4fad1c955f6-20261123T092740Z-qpFf1X.tar.gz`; **SHA-256** `52489dbaea4b4b4d5091a15f16dd6f03116cac178fa5cc84d8ec054534a2568f`. The binary archive is retained by the maintainer and not checked into the public repository.
- **Provenance:** fresh detached clone at exact SHA `a4fad1c955f6cfc09d9939d5d2db2b96692b5d89`, clean Git worktree before/after, 14/14 recorded steps `PASS`, zero `FAIL`/`BLOCKED`, `exit_code=0`. UTC 09:27:40–09:48:04 on 2026-11-23.
- **Host:** Mac Studio Mac16,9 (arm64, 64 GiB); macOS 27.3 `26C5047e`; Xcode 27.2 `27B52`; Apple Swift 6.4.2 `swiftlang-6.4.2.1.9`; SDK 27.2; Node 24.22.3; npm 11.19.1.
- **Before/after root lock SHA-256:** `23a354f8c238d90c90af5c19fd44703909ed76bcb6105f187499422c8f57fe63`.
- **Before/after fixture lock SHA-256:** `2f80539ae59ba58ac8670fbf780476cfb8d6cf74561ae636449932a3289c9a47`. Each lockfile has 29 pins. No source, dependency or graph drift.
- **Selected dependency revisions:** Core `d892bd34add1ad067ae6f286bd74c824486d8c07` (resolved from mutable manifest `main`), SwiftNIO `2f58d8ef84438d6517fc78bcea2f8527e3c72936` (2.105.0), swift-http-server `0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9`, Swift-JSON 1.9.0.
- **Current Core branch caveat:** Core `main` at this review was `e74557366c04a671973403f6911cb60fc02a88e3`, distinct from this run's locked Core commit. *A lock does not make the HTTP manifest's Core branch dependency immutable for new consumers.*

| Exact test stage | Studio FULL outcome | Qualification limit |
| --- | --- | --- |
| Focused HTTP lifecycle | Debug 4/4, Release 4/4 | Actual selected tests executed, not empty-filter success |
| Full SDK tests | Debug **116/116**, Release **116/116** | Three existing early-EOF tests each reported as **known issues**, not functional passes |
| HTTP optimized root + fixture links | Library, server, client **PASS** | Only the pinned pre-0.5 swift-http-server revision |
| Optimized fixture suite | **7/7 PASS** | Includes both real process/SIGTERM/open-subscription shutdown tests |
| Server referee | Debug **37/37 required + 13/13 extensions**, Release same | Three additional scenarios explicitly *not scored* in each mode; exit 0 |
| Client referee | Debug and Release: **37 scenarios, 399/399 checks** each | No failures/warnings reported by referee; required coverage mapping still an RC audit |
| Runner integrity | Root/fixture graph verified, SHA matched, worktree/locks unchanged | Release-toolchain versions are scoped to this host |

The 116 SDK tests per mode break down as **56 HTTP, 7 HTTP Client, 20 HTTP Authorization, 33 OAuth Client**. The two previously problematic OAuth tests passed in focused Debug/Release *and* both full suites. These counts are extracted from the native test logs, not inferred from a build exit code. The TLS negative trust case can emit an expected local curl certificate error while its test passes.

### Independent host evidence: lifecycle, not duplicate FULL release proof

- [Merged PR #23](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/pull/23): `7ed6fc14ff86ee69064e2249c836c931df86e1c5` with tree `3c9b8c6be010fac09692460f8f85408e60c5690d`, **identical** to merge commit `7287b61910e713b5790f57e111e8d9273f46996c` tree.
- MacBook **focused** 4/4 Debug and 4/4 Release; Studio **focused** 4/4 Debug and 4/4 Release on this same tree and matching lockfiles. Separate [PR #23 full CI](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45077961678) and [postmerge main CI](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions/runs/45137011997) completed successfully.
- In optimized native tests, an end-of-computation provider can report `timeout=1 returned=1 cancelled=0` while its queued HTTP output times out; a deliberately pending provider reports `timeout=1 returned=0 cancelled=1`. Both must prove resource zeroing **before** the test reads the blocked socket or shuts down the listener and a subsequent request on the same listener. **Provider completion ≠ delivery acknowledgment.**
- The Studio full test on the previous commit `7ed6fc14` **failed** in the OAuth issuer-change assertion; an earlier Studio full attempt **failed preflight** on Node 25 (the project pins Node 24). Neither historical run was retroactively marked green.

### OAuth issuer-isolation correction to integrate

[PR #24](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/pull/24) is **test-only**: `Tests/MCPClientAuthorizationTests/OAuthClientTests.swift`, +41/−2 versus `main`; no production OAuth behavior altered. Original test searched opaque request bodies for the two-character `r1` refresh-token string. A randomly generated 43-character Base64URL PKCE `code_verifier` may legitimately contain `r1`. The new test checks **protocol fields and headers**, new-issuer URL sequence, new client identity, and stored issuer-specific credentials; a deterministic verifier-collision regression makes the former false-positive path explicit.

**Causality limit:** The original failed request body was not recorded. We can demonstrate the false-positive path and successful strict tests; we cannot prove that the precise historical failure was caused by that field, nor claim all possible credential-leak scenarios are thereby disproven.

## 2. 1.0 release gates — decision matrix

| ID | Gate and acceptance | Current status | Tracking |
| --- | --- | --- | --- |
| INT-01 | Merge isolated OAuth test fix only after review + exact PR CI; independently verify resulting main tree and postmerge CI | **OPEN**: PR #24 submitted, separate Studio FULL PASS | [PR #24](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/pull/24) |
| NET-01 | Darwin peer FIN/RST/EOF cancellation correctness, including TLS, **without** `withKnownIssue` | **NO-GO**: 3 known issues remain; upstream early-EOF PR open at snapshot | [#12](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/12), [swift-nio #3783](https://github.com/apple/swift-nio/pull/3783) |
| WRITE-01 | Explicit native bounded **response-head and static-response writes**, cancellation+join and ownership recovery in Debug/Release | **NO-GO**: source-level gap documented, not yet behaviorally qualified | [#25](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/25) |
| DEP-01 | Choose and qualify official stable swift-http-server dependency under optimized ARM64 server consumer + fixture/referees | **NO-GO for 0.5.0**: PR #21 fails Swift Build aggregated Reader metadata symbols; alternate native-backend link experiment is not a shipping fix | [#13](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/13), [PR #21](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/pull/21) |
| CORE-01 | Approved immutable Core semantic version/tag, HTTP manifest revision/compatibility matrix, fresh consumer and locked graph | **NO-GO**: `branch: "main"` mutable (even though local locks are fixed) | [#14](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/14) |
| PLATFORM-01 | Written macOS/Swift floor and explicit Linux, iOS, older macOS non-goals; Linux build is compile-only until runtime verified | **PARTIAL**: macOS 27 + Swift 6.4 declared and qualified; Linux optimized builds observed but no Linux HTTP runtime promise | [#13](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/13) |
| QUALITY-01 | Official 2026-07-28 server **and client** required/extension scope, docs, public API review, license/SBOM, security checks, external consumer | **PARTIAL**: referee scenarios pass, but client required mapping, package docs and redistribution audit still open | [#14](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/issues/14) |
| RC-01 | On final immutable integration SHA: fresh macOS Debug/Release tests + optimized server/client fixture + both referees, Linux declared build gate; clean provenance, zero unexpected failures | **PENDING** all prior gates and final candidate | [CI](https://github.com/ThorFuchs/Swift-MCP-Server-HTTP/actions) |

**No-Go interpretation:** `PASS with known issues` is **not** evidence that the three Darwin peer-close cases work. `37/37 required` on the server and 399 client checks do not by themselves certify all supported platforms, a particular Code/PKCE random choice, or an immutable dependency graph.

## 3. Controlled integration and subsequent release sequence

1. **OAuth isolation PR (now):** maintain one-file diff, review the structured field assertions and deterministic regression, inspect exact PR commit/tree and required CI. Do not merge if regression, locked source drift, or unexpected scope appears. After merge, require clean postmerge checks; update this ledger with new commit and CI run.
2. **Documentation-only review:** bring this dated ledger into `main` through a separate reviewable change; do not use a documentation PR to obscure failing tests or run two competing self-hosted macOS matrices simultaneously.
3. **Lifecycle follow-up:** in a separate implementation PR, first reproduce blocked response-head and static writes, then establish one cancellable + joined owner for each move-only outbound writer. Preserve timeouts and wire format. Qualify on real sockets.
4. **SwiftNIO dependency:** monitor upstream #3783; when an approved version is available, adopt its exact tested revision, remove the three known-issue guards and rerun FIN/RST/TLS disconnect stress tests. A fork/local patch is not implicit approval.
5. **HTTP-server dependency:** isolate `0.5.0` private-external Reader metadata visibility through Swift Build's partial object link and find an upstream or supported tooling fix. The native-backend link success is diagnostic only; no deprecated backend as default without an explicit decision.
6. **Core release dependency:** coordinate approved Core RC/tag and replace mutable branch reference; qualify independent fresh SwiftPM consumer, server and client products, root/fixture consistency and whole compatibility matrix.
7. **Final RC gate:** freeze SHA + versions and platform contract; run the complete matrix and inspect raw logs, known issues, artifacts, license/source provenance and security review. Record explicit Go/No-Go with reviewers. **Only after Go:** create signed/versioned tag and publish the release; no tags/releases are authorized by this document alone.

## 4. Provenance and review hygiene

- Preserve full logs outside the repository; link recorded SHA-256 + exact source commit, checked host/compiler and workflow URLs. Do not publish host paths or credentials.
- Never infer green from an unexecuted test (`BLOCKED`), from a fixture that only compiles, or from a known-issue marker.
- This decision matrix covers the HTTP SDK; Core 1.0 is a separate release decision.
- At snapshot, public HTTP main manifest still uses swift-http-server raw revision `0b8f1691…`; the `0.5.0` upgrade is intentionally not merged.
- Preflight measured about 14 GiB free (97% used) on Studio. Preserve artifacts first, then reclaim old **fresh build directories** deliberately; do not delete the checked-out source, the sole archived evidence, or runner work directories while jobs are active.

**Release recommendation as of 2026-11-23:** **Integrate the isolated green OAuth test correction after review and CI; do not publish an HTTP 1.0.0 release candidate until the network, write-deadline and immutable dependency gates have concrete passing evidence.**
