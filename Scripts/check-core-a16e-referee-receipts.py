#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail closed on missing, duplicate or empty B3 referee results."""
import json
from pathlib import Path
import re
import sys

CLIENT = """
tools_call request-metadata sep-2322-client-request-state http-standard-headers
http-custom-headers http-invalid-tool-headers json-schema-ref-no-deref json-schema-2020-12-preservation
sep-2640-client-no-prefetch sep-2640-client-verify-digest sep-2640-client-verify-size sep-2640-client-verify-frontmatter
auth/metadata-default auth/metadata-var1 auth/metadata-var2 auth/metadata-var3 auth/metadata-issuer-mismatch
auth/resource-mismatch auth/basic-cimd auth/pre-registration
auth/token-endpoint-auth-basic auth/token-endpoint-auth-post auth/token-endpoint-auth-none
auth/iss-supported auth/iss-not-advertised auth/iss-supported-missing auth/iss-wrong-issuer auth/iss-unexpected auth/iss-normalized
auth/scope-from-www-authenticate auth/scope-from-scopes-supported auth/scope-omitted-when-undefined
auth/scope-step-up auth/scope-retry-limit auth/offline-access-scope auth/offline-access-not-supported
auth/authorization-server-migration
""".split()
SKILLS = "sep-2640-skills-enumeration sep-2640-skills-manifest sep-2640-skills-directory".split()
GATED = set(SKILLS + """
tasks-lifecycle tasks-capability-negotiation tasks-wire-fields tasks-request-state-removal
tasks-mrtr-input tasks-request-headers tasks-dispatch-and-envelope tasks-status-notifications
tasks-required-task-error tasks-mrtr-composition
""".split())
PENDING = "tasks-status-notifications"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def exits(path, names):
    lines = path.read_text().splitlines()
    require(lines and lines[0] == "scenario\treferee_exit", f"bad exit ledger: {path}")
    result = {}
    for line in lines[1:]:
        name, code = line.split("\t")
        require(name not in result, f"duplicate referee exit: {name}")
        result[name] = int(code)
    require(set(result) == set(names), f"exit inventory differs: {path}")
    return result


def counts(path):
    checks = json.loads(path.read_text())
    require(isinstance(checks, list), f"not a checks array: {path}")
    require(all(isinstance(c, dict) and isinstance(c.get("status"), str) for c in checks),
            f"malformed check: {path}")
    statuses = [c["status"] for c in checks]
    return statuses.count("SUCCESS"), statuses.count("FAILURE"), statuses.count("WARNING")


def server(out, log):
    # Preserve the repository's scored vs unscored policy. Do not count pending
    # diagnostics as executed successful checks just because a directory exists.
    require("required scenarios: 37/37 passed" in log, "missing required server summary")
    require(f"implemented extension scenarios: {len(GATED)}/{len(GATED)} passed" in log,
            "missing extension-gate summary")
    receipt = exits(out / "referee-exits.tsv", ["server-default"] + SKILLS)
    require(all(receipt[n] == 0 for n in SKILLS), "forced Skills scenario failed")
    stdout = (out / "referee.stdout").read_text(errors="replace")
    unscored = set()
    if "Not scored" in stdout:
        for line in stdout.split("Not scored", 1)[1].splitlines():
            match = re.match(r"\s+[✓✗]\s+(\S+)\s+\(", line)
            if match:
                unscored.add(match[1])
    records = {}
    for group in ("results", "extensions"):
        for directory in sorted((out / group).iterdir()):
            if not directory.is_dir():
                continue
            match = re.fullmatch(r"server-(.+)-\d{4}-\d{2}-\d{2}T[\d-]+Z", directory.name)
            require(match is not None, f"unexpected server directory: {directory.name}")
            name = match[1]
            require(name not in records, f"duplicate server scenario: {name}")
            records[name] = counts(directory / "checks.json")
    required = set(records) - unscored - GATED
    require(len(required) == 37, f"expected 37 scored scenarios, got {len(required)}")
    require(GATED <= records.keys(), f"missing extension gates: {sorted(GATED - records.keys())}")
    pending = []
    for name in sorted(required | GATED):
        passed, failed, warnings = records[name]
        require(failed == 0, f"failed server scenario: {name}")
        if not passed and name == PENDING and name in unscored:
            pending.append(name)
        else:
            require(passed > 0, f"no successful checks: {name}")
    require(receipt["server-default"] == 0 or
            any(records[n][1] for n in set(records) & unscored - GATED),
            "unexplained nonzero default referee exit")
    print(f"PASS: {len(required)}/37 required; {len(GATED)-len(pending)} extension gates with successful checks")
    print(f"Pending extension gates (not execution passes): {pending}")
    print(f"Unscored diagnostics outside extension gates: {len(unscored - GATED)}; "
          f"default referee exit: {receipt['server-default']}")
    print(f"Raw check totals (all recorded scenarios): {sum(v[0] for v in records.values())} success, "
          f"{sum(v[1] for v in records.values())} failure, {sum(v[2] for v in records.values())} warning")


def client(out, log):
    receipt = exits(out / "referee-exits.tsv", CLIENT)
    require(all(code == 0 for code in receipt.values()), "nonzero client scenario exit")
    successful = re.findall(r"^ok\s+(\S+):\s+Passed:\s*(\d+)/(\d+),\s*0 failed", log, re.M)
    require(len(successful) == len(CLIENT) and {n for n, _, _ in successful} == set(CLIENT),
            "missing, duplicate or unexpected client scenario summary")
    for name, passed, total in successful:
        require(int(passed) == int(total) > 0, f"empty or incomplete client summary: {name}")
        stem = name.replace("/", "-")
        raw = list((out / stem).rglob("checks.json"))
        require(len(raw) == 1, f"expected one client checks.json: {name}, found {len(raw)}")
        a, b, warnings = counts(raw[0])
        require(a == int(passed) and b == 0, f"raw client checks disagree: {name}")
        print(f"{name}: {a}/{a} checks; {warnings} warnings")
    print(f"PASS: {len(successful)}/{len(CLIENT)} named client scenarios")


def main():
    require(len(sys.argv) == 4, "usage: checker server|client OUTPUT_DIR SCRIPT_LOG")
    kind, directory, logfile = sys.argv[1:]
    require(kind in ("server", "client"), f"unknown leg {kind}")
    out = Path(directory)
    require((out / "referee-version.txt").read_text().strip() == "0.2.0-alpha.12", "wrong referee version")
    require(re.match(r"^[0-9a-f]{64}  .+", (out / "fixture.sha256").read_text()), "missing fixture digest")
    {"server": server, "client": client}[kind](out, Path(logfile).read_text(errors="replace"))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
