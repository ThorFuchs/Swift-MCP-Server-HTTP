# ADR-0001: Lean development process

- Status: **Accepted** (2026-11-10)
- Replaces: the gate/receipt process of the pre-1.0 repository (now archived privately); shared with Swift-MCP-Server

## Context

The pre-1.0 line was developed under a heavy governance process: dated gates, receipts,
recovery/return packs. It produced far more evidence than code and contradictory status
records. This repository starts fresh with the consolidated source only.

## Decision

1. **Git + PRs.** `main` is protected and releasable. Work happens on short-lived branches
   (`feat/`, `fix/`, `docs/`, `chore/`). PRs are squash-merged. No force pushes to `main`.
2. **CI is the evidence.** A PR merges only when the required checks pass: build, the full
   test suite including subprocess fixtures, and documentation generation. There are no
   hand-written receipts.
3. **Short ADRs** in `Docs/ADR/NNNN-title.md` (≤ 1 page) for changes to public API,
   dependencies, platform floor, security posture or release scope.
4. **Releases** use SemVer tags from `main`, with a CHANGELOG entry. Pre-releases are `-rc.N`.
5. **Dependencies** use version ranges for public products. Any patched or vendored
   dependency needs an ADR and an upstream issue/PR link. Swift-JSON stays an external
   dependency and is never duplicated here.
6. **Engineering invariants** (see AGENTS.md): Swift tools 6.4, Swift 6 mode, macOS 27+;
   no unsafe flags, retroactive `Sendable`, silent validation skips, network schema fetches
   or detached unowned tasks; the library never bootstraps process-global logging/metrics,
   installs signal handlers or owns host credentials; `Reference/` bytes and upstream
   licenses are immutable.

## Consequences

- Status lives in CI and the CHANGELOG only.
- CI needs a macOS 27 runner. GitHub-hosted runners do not provide Xcode 27 yet, so a
  self-hosted runner is used.
