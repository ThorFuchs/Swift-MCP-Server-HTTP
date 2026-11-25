# H1 — Official SwiftNIO release integration (HTTP #12)

## Contract

Require SwiftNIO from 2.105.2. The exact H1 candidate is the official 2.105.2 tag at
`b003027fc38b649a43e9aad77c3d4e4a2c5b6997`, which contains Apple PR #3783
(merge `a7d4e6b50c9be24d3a55f1a50e6e52bfc1d683d5`).
The prior six-execution diagnostic proof is available in Actions run 45231924025;
it was against the upstream merge, not the released tag. Do not count it as H1.

H1 is based on HTTP main `d2e4cb5a07b4f2453ccd8106d799ca548470c202`.
Both lockfiles are seeded with the official NIO pin; every other pin, including
Core branch:main and its recorded revision, must be unchanged. The unverified
originHash fields are deliberately omitted from the candidate locks. Native
SwiftPM 6.4.2 must regenerate them. Review and commit those generated lockfiles
before the final exact-head matrix. Do not promote the seed locks as final
resolution evidence.

Three existing native disconnect tests are mandatory in Debug and Release.
The old known-issue scopes are replaced by ordinary do scopes; the assertions,
deadlines and test bodies are otherwise unchanged. No production runtime,
HTTP-server dependency, referee or CI timeout change is in H1.

## Native run

Use an otherwise idle native ARM64 macOS 27+ machine, Swift 6.4.2, Python 3
and the project's pinned Node major. Start from a fresh, detached, clean
checkout of the exact H1 commit. Do not run timing-sensitive Core jobs in
parallel on the same physical machine.

    python3 -I Scripts/qualify-h1.py EXACT_HTTP_SHA "$HOME/MCP-H1-Evidence" full

Use `focused` instead of `full` to run just the graph and six native tests.
The runner checks both graphs against the immutable H1 baseline, verifies
actual NIO/Core checkout HEADs, runs each named test separately and rejects
known-issue results or empty test filters. Full mode then runs Debug SDK,
Debug server/client referees, optimized libraries and both executable fixtures,
Release SDK/fixture tests and Release server/client referees.

The archive contains provenance, raw logs, passed stages, both native-resolved
lockfiles and their tracked diff. Inspect `decision.json` and
`focused-PASS.txt` separately from the overall exit. A later #20 linker
failure must not obscure a completed focused proof; it also must not be
described as a green release matrix.

If resolution changes any non-NIO pin, stop and inspect both locks. Do not
accept a newer mutable Core revision just to obtain a passing result. If the
runner reports an origin-hash or checkout-layout error, treat that as a setup
failure, not evidence about TCP behavior. No edits to the normal dependency
requirements, tests or timeouts to get the proof green.

## Release disposition

- Review the six real test executions against the released tag.
- Review native lockfiles; commit only admitted lockfile regeneration.
- Run the full exact-head matrix, including existing Linux compile-only CI.
- If optimized linking is still blocked by #20, retain H1 focused evidence,
  qualify #20 independently, then qualify the combined graph.
- Open/review a PR after the native pre-PR checks required by AGENTS.md.
- Close HTTP #12 only when the real release graph and its acceptance checks
  are integrated. HTTP #13, #25 and #14 remain independent gates.

Authoring host: syntax check and seven synthetic lock acceptance/rejection
controls passed for the runner. The native HTTP build and actual H1 tests have
not yet run. No release tag, main merge or issue closure is authorized by this
document.
