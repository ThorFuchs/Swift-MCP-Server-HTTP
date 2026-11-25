# H5.3 — Exact server conformance gate

Status: implemented; offline regression and historical-evidence replay PASS.
Fresh native referee execution on this candidate remains pending. Not an RC GO.

Base: H5.2 `14439197b93523c8005a79008862bde84c6d9218`.
Integrated HTTP baseline: `2cbedd510b15f510c24373ea45ca4fc9cf754cbe`.
No changes to Swift runtime sources, dependency manifests/locks, referee version,
Core repository, reference bytes or CI routing.

## Frozen source and gate policy

The shared parser reads the actual fixture Core checkout, checks its revision
against both root and fixture locks, and verifies the immutable requirements
Git blob `b0c4f8560429e8f4b6c89833cc0b35405bc004ff`. The audited Core revision
is `d892bd34add1ad067ae6f286bd74c824486d8c07`. The corresponding [reference](https://github.com/ThorFuchs/Swift-MCP-Server/blob/d892bd34add1ad067ae6f286bd74c824486d8c07/Reference/Conformance/requirements/2026-07-28.yaml)
matches the pinned referee's [requirements file](https://github.com/modelcontextprotocol/conformance/blob/f44482ba17df816d3176962a11cdf36aec9bda00/requirements/2026-07-28.yaml)
byte-for-byte. The installed referee remains 0.2.0-alpha.12; the frozen
requirements anchor is alpha.10.

| Category | Expected receipts | Acceptance |
| --- | ---: | --- |
| Frozen server required | 37 | Positive SUCCESS count, no FAILURE or unexpected SKIPPED; report WARNING |
| Tasks extensions | 10 | Same policy, with the one exact known upstream skip below |
| Pending diagnostics | 3 | Present, valid and executed; report diagnostic success/failure without scoring |
| Skills extensions | 3 | Separate forced invocations; valid executed checks, no failure/unexpected skip |
| Total | 53 | Exact set and one receipt per scenario |

The official server `--requirements` [exit policy](https://github.com/modelcontextprotocol/conformance/blob/f44482ba17df816d3176962a11cdf36aec9bda00/src/index.ts)
ignores failures in non-scored cases, so a nonzero suite exit is not
exempted merely because pending diagnostics exist. The local gate additionally
enforces implemented extensions, unique complete receipts and positive executed
checks. Warnings retain the official server semantics and are visible, not
counted as SUCCESS. The client warning policy remains unchanged.

The pinned [Tasks notification scenario](https://github.com/modelcontextprotocol/conformance/blob/f44482ba17df816d3176962a11cdf36aec9bda00/src/scenarios/server/tasks/notifications.ts)
emits one SKIPPED check without opening the subscriptions/listen stream.
Its observation harness needs rewriting. Accept only its precise check ID
and skip reason, in the Tasks category and as a single-check receipt.
Report KNOWN_UPSTREAM_SKIP, never PASS. A future actually executed scenario
must meet the normal passing criteria. Other skips fail this pinned gate.
Actual Tasks status-notification delivery is not qualified by this skip.

## Implementation

- `client-conformance-gate.py` shares frozen server category selection with
  `conformance_summary.py`; client selection and policy are unchanged.
- `conformance.sh` uses forced resolved versions, a fresh evidence directory,
  the existing loopback fixture and the 90 s per-scenario referee timeout.
- The Python server runner invokes the official requirements suite and the
  three Skills scenarios separately, retaining each exit code and log.
- Validate raw receipt set, directory names, nonempty check arrays, IDs and
  statuses; match suite start names, per-scenario success/failure totals,
  aggregate totals and non-scored reasons to the independently derived plan.
  Match each Skills invocation name and printed counts to its raw receipt.
  Verify the Core plan again after execution.
- Output plan.json, process-exits.json, individual logs and raw checks.
  A passing validation additionally writes summary.json. A failed run exits
  nonzero and preserves available raw evidence. The old combined extensions
  stdout is replaced by separate per-Skills stdout/stderr files.

## Evidence

Local Python syntax and Bash syntax validation passed. The 20 new server
unit tests and 12 existing client unit tests passed (32/32 test methods).
Tests include missing/duplicate receipts, invalid status, empty/unexecuted
cases, unexplained exits, summary mismatches, wrong classification, expected
skip and changed skip reason, warning reporting and pending diagnostic failure.
These are offline controls, not native network tests.

The locally inspected H1 archive `http-h1-9l6enh_w.tar.gz` has SHA-256
`8cfd14e434aff0d8a2ec434aa16a5885556cb8cea52ade394845c35a944eb289`.
The frozen YAML used in replay was byte-verified against the reference Git
blob. The new evaluator independently checked 53 raw receipts per mode,
the original aggregate stdout and split the historical combined Skills stdout
into its three invocation sections. The old runner recorded a combined zero
exit; replay supplied zero for the suite and each Skills process on that basis,
not independently captured historical process-exit receipts. New runs record
the actual four process statuses separately.

| Historical native replay | Debug | Release |
| --- | ---: | ---: |
| Required passed (includes warning-bearing scenario) | 37/37 | 37/37 |
| Tasks executed passing | 9/10 | 9/10 |
| Tasks known upstream skip | 1 | 1 |
| Skills passed | 3/3 | 3/3 |
| Pending diagnostics passed (not scored) | 3/3 | 3/3 |
| SUCCESS checks | 241 | 242 |
| FAILURE checks | 0 | 0 |
| WARNING checks | 1 | 0 |
| SKIPPED checks | 1 | 1 |
| New evaluator on historical evidence | PASS | PASS |

Debug warning: server-stateless / sep-2575-server-sends-prompts-list-changed-on-subscription.
The one skip in each mode is tasks-status-notifications. Historical H1's
13/13 extension gate count was a non-failure count; the more accurate
disposition is 12/13 passed plus one known upstream skip. This does not
invalidate the historical required conformance result or turn the skipped
check into evidence of delivery.

## Remaining qualification

Run the newly integrated server and client entrypoints with the real pinned
Swift/npm referee on macOS Debug and Release, together with the four DocC
catalog conversions. Historical replay did not exercise the new subprocess
or shell integration on native hardware. Continue public external consumer,
negative controls, final dependency/platform decisions and immutable Core/HTTP
pairing. Do not close #14 or #13 solely on this evidence; no tag or release.
