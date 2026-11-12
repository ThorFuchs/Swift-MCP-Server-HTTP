"""Summarise an official MCP conformance run from its raw checks.json files.

Usage: conformance_summary.py <results-dir> <referee-exit-code> [extension-results-dir]

Every scenario directory must contain a checks.json array. Scenarios that the referee lists as
"Not scored" (optional extensions and pending cases) do not count as required, except the
extension scenarios this package implements (GATED): each of those must be present and free of
failures. Any scored or gated scenario with a FAILURE check, or a missing/malformed
checks.json, fails the run.
"""
import json
import pathlib
import re
import sys

# Extension scenarios implemented by the fixture (MCPTasks, MCPSkills). The referee skips
# tasks-status-notifications itself (pending its subscriptions/listen rewrite).
GATED = {
    "tasks-lifecycle", "tasks-capability-negotiation", "tasks-wire-fields", "tasks-request-state-removal",
    "tasks-mrtr-input", "tasks-request-headers", "tasks-dispatch-and-envelope", "tasks-status-notifications",
    "tasks-required-task-error", "tasks-mrtr-composition",
    "sep-2640-skills-enumeration", "sep-2640-skills-manifest", "sep-2640-skills-directory",
}


def main() -> int:
    results = pathlib.Path(sys.argv[1])
    referee_exit = int(sys.argv[2])
    stdout = (results.parent / "referee.stdout").read_text(errors="replace")
    unscored = set()
    if "Not scored" in stdout:
        for line in stdout.split("Not scored", 1)[1].splitlines():
            match = re.match(r"\s+[✓✗]\s+(\S+)\s+\(", line)
            if match:
                unscored.add(match.group(1))

    scenarios = {}
    problems = []
    directories = [p for p in results.iterdir() if p.is_dir()]
    if len(sys.argv) > 3 and pathlib.Path(sys.argv[3]).is_dir():
        directories += [p for p in pathlib.Path(sys.argv[3]).iterdir() if p.is_dir()]
    for directory in sorted(directories):
        match = re.match(r"server-(.+)-\d{4}-\d{2}-\d{2}T[\d-]+Z$", directory.name)
        if not match:
            problems.append(f"unexpected result directory {directory.name}")
            continue
        name = match.group(1)
        try:
            checks = json.loads((directory / "checks.json").read_text())
            assert isinstance(checks, list)
        except Exception as error:  # malformed or missing output is a failure, never a skip
            problems.append(f"{name}: unreadable checks.json ({error})")
            continue
        statuses = [check.get("status") for check in checks]
        scenarios[name] = (statuses.count("SUCCESS"), statuses.count("FAILURE"), len(statuses))

    scored = {n: v for n, v in scenarios.items() if n not in unscored and n not in GATED}
    failed_scored = sorted(n for n, (_, failures, total) in scored.items() if failures or total == 0)
    passed_scored = len(scored) - len(failed_scored)
    print(f"required scenarios: {passed_scored}/{len(scored)} passed")
    for name in failed_scored:
        print(f"  FAIL {name}: {scored[name]}")
    gated_failed = sorted(n for n in GATED if n not in scenarios or scenarios[n][1])
    print(f"implemented extension scenarios: {len(GATED) - len(gated_failed)}/{len(GATED)} passed")
    for name in gated_failed:
        print(f"  FAIL {name}: {scenarios.get(name, 'missing')}")
    unscored -= GATED
    print(f"not scored: {len(unscored)} ({sum(1 for n in unscored if scenarios.get(n, (0, 1, 0))[1] == 0)} without failures)")
    for problem in problems:
        print(f"  ERROR {problem}")
    print(f"referee exit code: {referee_exit}")
    return 0 if scored and not failed_scored and not gated_failed and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
