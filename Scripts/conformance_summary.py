"""Summarise an official MCP conformance run from its raw checks.json files.

Usage: conformance_summary.py <results-dir> <referee-exit-code>

Every scenario directory must contain a checks.json array. Scenarios that the referee lists as
"Not scored" (optional extensions and pending cases) are reported but do not fail the run. Any
scored scenario with a FAILURE check, or a missing/malformed checks.json, fails it.
"""
import json
import pathlib
import re
import sys


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
    for directory in sorted(p for p in results.iterdir() if p.is_dir()):
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

    scored = {n: v for n, v in scenarios.items() if n not in unscored}
    failed_scored = sorted(n for n, (_, failures, total) in scored.items() if failures or total == 0)
    passed_scored = len(scored) - len(failed_scored)
    print(f"required scenarios: {passed_scored}/{len(scored)} passed")
    for name in failed_scored:
        print(f"  FAIL {name}: {scored[name]}")
    print(f"not scored: {len(unscored)} ({sum(1 for n in unscored if scenarios.get(n, (0, 1, 0))[1] == 0)} without failures)")
    for problem in problems:
        print(f"  ERROR {problem}")
    print(f"referee exit code: {referee_exit}")
    return 0 if scored and not failed_scored and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
