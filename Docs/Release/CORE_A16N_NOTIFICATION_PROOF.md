# Focused A1.6n notification latency proof

Baseline: B3 HTTP `c99b65a9ee7879187e6d67e9771b8daa30115502`, Core `02958abee82c363b879aa013c38229edb9a1c116`.
Candidate: Core draft PR #61 `044e2ab332d9f55632c900c13f23502acd8e8972`. Same B3 HTTP fixture and
referee 0.2.0-alpha.12. This separate diagnostic branch changes no production
Swift, normal manifests or locks.

The B3 archive contains a Debug SHOULD warning in server-stateless for prompt
list change. The prompt mutation's preparation/publication phase took
9.777 s; publish admission took 7.875 us. Release passed. The exact referee
window and dominant subphase are not established. PR #61 is a scoped
optimization candidate, not a verified fix.

Run from this exact diagnostic runner commit on idle Studio (Node 24,
Swift 6.4.2):

    bash Scripts/qualify-core-a16n-notifications.sh EXACT_RUNNER_SHA "$HOME/MCP-A16E-Evidence"

The runner creates separate disposable B3 checkouts and deliberately selects
an explicit Core revision in both manifests for each arm. Native SwiftPM
resolves those graphs; compare all 29 pin entries to the expected B3 graph
with only the Core revision/requirement changed. Require both actual Core
checkout SHAs. No hand-generated origin hash, no global config, no package
edit override. A resolver mismatch stops that arm and is evidence, not an
invitation to silently update dependencies.

Three fresh Debug fixture processes and one fresh Release fixture process
per arm run the existing official server-stateless scenario, same 90 s
referee and 60 s readiness bounds as B3. Verify all 30 raw checks; the
baseline may reproduce only the original prompt SHOULD warning (reported
as warning, not a pass). Candidate requires 30/30 SUCCESS, both real
notification frames, one actual initial catalog mutation per type, and
gracefully joined fixture. Record timings and compare after return; no
claimed speedup or root cause until measured. Archive checks, per-run
exit/receipt status and exact dependency bytes. Ordinary failure preserves
evidence; a drift or setup failure prevents dependent runs. Keep #61 draft
until full CI and focused proof; rerun full B3 on any final integrated SHA.
