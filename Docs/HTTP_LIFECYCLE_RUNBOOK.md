# HTTP lifecycle verification on MacBook and Mac Studio

Use the **same full HTTP commit SHA** on both machines. Each run starts in its own
fresh clone. The script rejects an unexpected commit, dirty checkout, or existing
root/fixture `.build` directory. It does not delete previous results or builds.

## Prerequisites

- macOS 27 or newer and the selected Xcode/Swift toolchain required by the package.
- Git, Python 3 and the Xcode command-line tools. The script records the macOS
  build, hardware, selected Xcode, Swift version, SDK, current load and free disk.
- For `full`: Node with the major version pinned in
  `Tools/Conformance/.nvmrc` and npm. Referee dependencies use the committed lock.
- Run one qualification at a time on each Mac. Stop or finish unrelated local/CI
  builds before starting; the recorded load is evidence, not proof of an idle host.

## Fresh clone and focused run

This is a **template**. Replace `REPLACE_WITH_FULL_40_CHARACTER_HTTP_COMMIT_SHA`
with the exact reviewed commit. Set `LIFECYCLE_MACHINE` to `macbook` on the
MacBook or `studio` on the Mac Studio. The enclosing Bash block also works when
pasted into an interactive zsh session.

```bash
bash <<'BASH'
set -euo pipefail
LIFECYCLE_MACHINE=studio
LIFECYCLE_SHA=REPLACE_WITH_FULL_40_CHARACTER_HTTP_COMMIT_SHA
[[ "$LIFECYCLE_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "Replace the SHA placeholder first" >&2; exit 64; }
LIFECYCLE_CHECKOUT="$(mktemp -d "$HOME/Swift-MCP-Lifecycle-$LIFECYCLE_MACHINE-XXXXXX")"
git clone --no-checkout https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git "$LIFECYCLE_CHECKOUT"
git -C "$LIFECYCLE_CHECKOUT" fetch origin "$LIFECYCLE_SHA"
git -C "$LIFECYCLE_CHECKOUT" checkout --detach "$LIFECYCLE_SHA"
cd "$LIFECYCLE_CHECKOUT"
bash -n Scripts/verify-http-lifecycle.sh
bash Scripts/verify-http-lifecycle.sh "$LIFECYCLE_MACHINE" focused "$LIFECYCLE_SHA"
BASH
```

`focused` resolves the root and fixture graphs independently, verifies their
shared dependencies and checks that the committed lockfiles remain unchanged.
It then runs these **four actual tests** once in Debug and once in Release:

| Scope | Invariant |
| --- | --- |
| Finite provider, stalled native writer | Normal provider return may precede failed delivery; all output ownership still releases. |
| Still-live provider, stalled native writer | A pending provider is actually cancelled; the same listener accepts a subsequent request. |
| CompletedProviderDrainTests | The normal provider return path does not release Core ownership while an explicitly held sink remains pending. |
| Native connection ceiling | Excess accepted connections are rejected and capacity recovers. |

A successful `swift test` exit alone is insufficient: the runner verifies that
all four named tests executed successfully exactly once across the test targets.
Zero-test reports from targets outside the filter do not count as execution; an
empty or unexpectedly changed selection fails verification. This focused run does not qualify the separate
fixture executable links or the complete protocol referee suite.

## Full qualification

Use another fresh clone with the **same SHA** and change `focused` to `full` in
the template. Full mode includes the focused checks, then runs:

1. `bash Scripts/test.sh -j 2` for the full Debug suite.
2. `bash Scripts/qualify-release.sh full` for optimized SDK/fixture builds and
   both optimized test suites.
3. The existing server and client referees against Debug and Release fixtures.

All Swift builds/tests use two jobs, including fixture builds in the referee
scripts. Dependency consistency is checked again at the end. Failed prerequisites
produce explicit `BLOCKED` results for later stages; those stages are not counted
as passes. Known issues retained by the full suite remain known issues.

## Results and comparison

The script prints the result directory and sibling `.tar.gz` archive. By default
they are under `$HOME/MCP-Lifecycle`; a fourth argument selects another directory
**outside the checkout**. Every run has a unique directory.

- `results.tsv` distinguishes the actual command exit from the additional
  nonempty-execution verification exit.
- `host.txt`, `source.txt`, before/after lockfiles and `dependencies.txt` establish
  host, source and dependency provenance.
- `logs/` contains complete output for every attempted step; `referees/` contains
  the referee outputs in full mode.
- `dependency-drift.diff`, final Git status and `summary.txt` report source drift
  and the overall run outcome.

The exit trap archives partial results on ordinary errors, Ctrl-C, termination
or SSH hangup once Bash processes that signal. SIGKILL or power loss cannot run
an exit trap; the result directory still retains files already written. A failed
archive is reported explicitly. Do not commit generated evidence to the repo.

Compare the exact HTTP SHA, actual dependency revisions, OS build, Swift and SDK
before comparing timings. A focused pass on both hosts qualifies these lifecycle
cases. A release decision additionally requires the full checks and resolution
of the separately tracked dependency/release blockers.
