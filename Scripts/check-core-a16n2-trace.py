#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""N2 diagnostic receipts, not a release gate."""
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys

TARGET = "sep-2575-server-sends-prompts-list-changed-on-subscription"


def need(value, message):
    if not value:
        raise ValueError(message)


def source(package, out):
    """Archive the actually installed public JS, never edit the referee."""
    pkg = json.loads((package / "package.json").read_text())
    need(pkg["version"] == "0.2.0-alpha.12", "wrong referee")
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(package / "package.json", out / "package.json")
    manifest = {}
    selected = []
    size = 0
    for p in sorted((package / "dist").rglob("*")):
        if not p.is_file() or p.is_symlink() or p.suffix not in (".js", ".mjs", ".cjs"):
            continue
        data = p.read_bytes()
        name = str(p.relative_to(package))
        manifest[name] = hashlib.sha256(data).hexdigest()
        size += len(data)
        need(size <= 32 * 1024 * 1024, "referee JS archive exceeds bound")
        dest = out / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)
        if any(x in data for x in (TARGET.encode(), b"ServerSendsPromptsListChangedOnSubscription",
                                   b"test_trigger_prompt_change")):
            selected.append(name)
    need(manifest and selected, "installed prompt scenario source not found")
    (out / "sha256.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (out / "scenario-files.json").write_text(json.dumps(selected, indent=2) + "\n")
    print("Archived exact installed referee JS:", len(manifest), "files,", size, "bytes")


TRACE = re.compile(r"^N2_TRACE ns=(\d+) seq=(\d+) event=(\S+) channel=(\S+) kind=(\S+)\s*(.*)$")
FIXTURE = re.compile(r"^N2_FIXTURE ns=(\d+) event=(\S+) kind=(\S+)$")


def inspect(out, enabled):
    log = (out / "fixture.stderr").read_text(errors="replace")
    records, mutations = [], []
    for line in log.splitlines():
        if line.startswith("N2_TRACE "):
            m = TRACE.fullmatch(line)
            need(m, "malformed Core trace record")
            ns, seq, event, channel, kind, detail = m.groups()
            records.append(dict(ns=int(ns), seq=int(seq), event=event,
                                channel=channel, kind=kind,
                                detail=dict(token.split("=", 1) for token in detail.split())))
        elif line.startswith("N2_FIXTURE "):
            m = FIXTURE.fullmatch(line)
            need(m, "malformed fixture trace record")
            ns, event, kind = m.groups()
            mutations.append(dict(ns=int(ns), event=event, kind=kind))
    if not enabled:
        need(not records and not mutations, "trace-disabled control emitted traces")
        print("Trace-disabled control verified")
        return
    need(records and mutations, "missing trace")
    need([r["seq"] for r in records] == list(range(1, len(records)+1)), "non-contiguous sequence")
    need(all(a["ns"] <= b["ns"] for a, b in zip(records, records[1:])), "nonmonotonic Core trace")
    need(not any(r["event"] == "trace.limit" for r in records), "trace truncated")
    for kind in ("prompts", "tools"):
        begins = [r for r in mutations if r["kind"] == kind and r["event"] == "publish.begin"]
        ends = [r for r in mutations if r["kind"] == kind and r["event"] == "publish.return"]
        need(begins and len(begins) == len(ends), f"missing {kind} publication pairs")
        need(any(r["kind"] == kind and r["event"] == "catalog.published" for r in mutations),
             f"missing real {kind} catalog mutation")
        for start, end in zip(begins, ends):
            need(start["ns"] <= end["ns"], "publication chronology invalid")
            selections = [r for r in records if r["event"] == "publish.select" and r["kind"] == kind
                          and start["ns"] <= r["ns"] <= end["ns"]]
            need(len(selections) == 1, f"expected one {kind} selection within publication")
            selection = selections[0]
            need(int(selection["detail"]["targets"]) <= int(selection["detail"]["entries"]),
                 "invalid target counts")
            print(f"{kind}: select ns={selection['ns']} {selection['detail']}")
    need(any(r["event"] == "subscription.register" for r in records), "no subscription admission trace")
    need(any(r["event"] == "sink.return" and r["kind"] == "ack" for r in records), "no ack write receipt")
    timeline = sorted(records + mutations, key=lambda r: r["ns"])
    first = timeline[0]["ns"]
    for r in timeline:
        r["elapsed_ms"] = round((r["ns"] - first) / 1_000_000, 3)
    (out / "timeline.json").write_text(json.dumps(timeline, indent=2) + "\n")
    with (out / "timeline.tsv").open("w") as f:
        f.write("elapsed_ms\tevent\tchannel\tkind\tdetail\n")
        for r in timeline:
            f.write(f"{r['elapsed_ms']:.3f}\t{r['event']}\t{r.get('channel', '-')}\t"
                    f"{r['kind']}\t{json.dumps(r.get('detail', {}), sort_keys=True)}\n")
    print("PASS: complete diagnostic timeline;", len(records), "Core records")
    print("sink.return is local write completion, not remote receipt")


def main():
    if sys.argv[1] == "source":
        source(Path(sys.argv[2]), Path(sys.argv[3]))
    elif sys.argv[1] == "trace":
        need(sys.argv[3] in ("0", "1"), "trace mode")
        inspect(Path(sys.argv[2]), sys.argv[3] == "1")
    else:
        raise ValueError("unknown command")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, IndexError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
