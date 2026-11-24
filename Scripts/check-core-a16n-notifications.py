#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A1.6n: exact diagnostic pins and focused official referee receipts."""
import json
from pathlib import Path
import re
import sys

WORKSPACES = (Path("."), Path("Tools/Conformance/SwiftFixture"))
CORE = "02958abee82c363b879aa013c38229edb9a1c116"
NIO = "b003027fc38b649a43e9aad77c3d4e4a2c5b6997"
SQLITE = "df12fe55265de81e2fc4bca91cb85704343b528f"
PREFIX = "sep-2575-server-sends-"
TARGETS = {"prompts": PREFIX + "prompts-list-changed-on-subscription",
           "tools": PREFIX + "tools-list-changed-on-subscription"}


def need(value, message):
    if not value:
        raise ValueError(message)


def load(path):
    return json.loads(path.read_text())


def pins(path):
    entries = load(path)["pins"]
    result = {p["identity"]: p for p in entries}
    need(len(entries) == len(result) == 29, f"expected 29 unique pins: {path}")
    return result


def seed(sha, out):
    need(re.fullmatch(r"[0-9a-f]{40}", sha), "exact Core revision required")
    original = [pins(w / "Package.resolved") for w in WORKSPACES]
    need(original[0] == original[1], "B3 workspace pins differ")
    need(original[0]["swift-mcp-server"]["state"] == {"branch": "main", "revision": CORE}, "not B3 Core pin")
    need(original[0]["swift-nio"]["state"] == {"revision": NIO, "version": "2.105.2"}, "NIO differs")
    need(original[0]["swift-sqlite"]["state"] == {"revision": SQLITE, "version": "1.2.0"}, "SQLite differs")
    for workspace in WORKSPACES:
        manifest = workspace / "Package.swift"
        text = manifest.read_text()
        old = '.package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", branch: "main")'
        new = '.package(url: "https://github.com/ThorFuchs/Swift-MCP-Server.git", revision: "' + sha + '")'
        need(text.count(old) == 1, f"unexpected Core dependency: {manifest}")
        manifest.write_text(text.replace(old, new))
        lock = workspace / "Package.resolved"
        data = load(lock)
        for pin in data["pins"]:
            if pin["identity"] == "swift-mcp-server":
                pin["state"] = {"revision": sha}
        # Native SwiftPM resolve must compute its own origin hash. Seed only
        # the selected revision; never manufacture a new originHash.
        lock.write_text(json.dumps(data, indent=2) + "\n")
    expected = pins(WORKSPACES[0] / "Package.resolved")
    need(expected == pins(WORKSPACES[1] / "Package.resolved"), "seed graph mismatch")
    (out / "expected-pins.json").write_text(json.dumps(expected, indent=2, sort_keys=True) + "\n")


def verify(out):
    expected = load(out / "expected-pins.json")
    for label, workspace in zip(("root", "fixture"), WORKSPACES):
        path = workspace / "Package.resolved"
        actual = pins(path)
        differences = sorted(k for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k))
        need(not differences, f"{label} pin drift: {differences}")
        (out / (label + ".resolved.json")).write_bytes(path.read_bytes())
        checkout = list((workspace / ".build" / "checkouts").glob("*"))
        core = [p for p in checkout if p.name.lower() == "swift-mcp-server"]
        need(len(core) == 1, f"{label}: missing real Core checkout")
        import subprocess
        actual_sha = subprocess.check_output(["git", "-C", str(core[0]), "rev-parse", "HEAD"], text=True).strip()
        need(actual_sha == expected["swift-mcp-server"]["state"]["revision"], f"{label}: wrong checked-out Core {actual_sha}")
    print("PASS: all 29 pins and both actual Core checkouts")


def receipt(arm, out):
    files = list((out / "results").rglob("checks.json"))
    need(len(files) == 1 and files[0].parent.name.startswith("server-server-stateless-"), "missing or multiple stateless scenario receipts")
    checks = load(files[0])
    need(isinstance(checks, list) and len(checks) == 30, "expected 30 stateless checks")
    warnings = [x["id"] for x in checks if x["status"] == "WARNING"]
    need(all(x["status"] in ("SUCCESS", "WARNING") for x in checks), "failed, skipped or unknown stateless status")
    need(not warnings or (arm == "baseline" and warnings == [TARGETS["prompts"]]),
         f"unaccepted warnings: {warnings}")
    for kind, target in TARGETS.items():
        matches = [x for x in checks if x["id"] == target]
        need(len(matches) == 1, f"missing/duplicate {target}")
        check = matches[0]
        if check["status"] == "WARNING":
            need(arm == "baseline" and kind == "prompts", f"unexpected warning: {target}")
            continue
        frame = check["details"]["changeFrame"]
        need(frame["method"] == f"notifications/{kind}/list_changed", f"wrong notification method: {target}")
        need(frame["params"]["_meta"]["io.modelcontextprotocol/subscriptionId"] is not None,
             f"missing subscriptionId: {target}")
    log = (out / "fixture.stderr").read_text(errors="replace")
    need("FIXTURE_STOPPED started=2 joined=2 active=0" in log, "fixture did not prove graceful join")
    for kind in TARGETS:
        matches = re.findall(r"^FIXTURE_MUTATION kind=" + kind +
                             r" construction_ns=(\d+) preparation_publication_ns=(\d+)"
                             r" notification_admission_ns=(\d+) total_ns=(\d+)$", log, re.M)
        first = [tuple(map(int, m)) for m in matches if int(m[1]) > 0]
        need(len(first) == 1, f"expected one real initial {kind} catalog mutation: {first}")
        construction, prep, notification, total = first[0]
        print(f"{kind}: construction_ns={construction} preparation_publication_ns={prep} "
              f"notification_admission_ns={notification} total_ns={total}")
    print(f"{arm}: {30-len(warnings)}/30 SUCCESS; {len(warnings)} WARNING")


def main():
    command = sys.argv[1]
    if command == "seed":
        seed(sys.argv[2], Path(sys.argv[3]))
    elif command == "verify":
        verify(Path(sys.argv[2]))
    elif command == "receipt":
        receipt(sys.argv[2], Path(sys.argv[3]))
    else:
        raise ValueError("unknown action")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, IndexError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
