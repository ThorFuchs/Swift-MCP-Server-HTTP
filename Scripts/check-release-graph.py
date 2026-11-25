#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Verify that root and conformance fixture resolve consistent release dependencies.

This does not bless the mutable Core branch:main as a stable 1.0 dependency.
"""
import json
from pathlib import Path
import sys

SHARED = (
    "swift-mcp-server", "swift-json", "swift-http-server", "swift-nio",
    "swift-http-api-proposal", "swift-collections",
)
HTTP_SERVER_SHA = "0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9"


def pins(path):
    entries = {}
    for item in json.loads(Path(path).read_text(encoding="utf-8"))["pins"]:
        identity = item["identity"].lower()
        if identity in entries:
            raise ValueError(f"duplicate pin: {identity}")
        entries[identity] = item["state"]
    return entries


def main():
    if len(sys.argv) != 3:
        raise ValueError("usage: check-release-graph.py root-resolved fixture-resolved")
    root, fixture = (pins(p) for p in sys.argv[1:])
    for identity in SHARED:
        if identity not in root or identity not in fixture:
            raise ValueError(f"missing shared package: {identity}")
        r, f = root[identity], fixture[identity]
        if not r.get("revision") or r["revision"] != f.get("revision"):
            raise ValueError(f"root/fixture {identity} revision mismatch: {r} / {f}")
        print(f"{identity} = {r['revision']} ({r.get('version', r.get('branch', 'revision'))})")
    nio = root["swift-nio"]
    nio_version = nio.get("version", "")
    if nio_version != fixture["swift-nio"].get("version"):
        raise ValueError("root/fixture SwiftNIO version mismatch")
    parts = nio_version.split(".")
    if len(parts) != 3 or any(not part.isascii() or not part.isdecimal() for part in parts):
        raise ValueError(f"SwiftNIO must be a stable semantic version: {nio_version!r}")
    if not (2, 105, 2) <= tuple(int(part) for part in parts) < (3, 0, 0):
        raise ValueError("SwiftNIO must include the macOS early-EOF fix (2.105.2+ in 2.x)")
    if nio_version == "2.105.2" and nio["revision"] != "b003027fc38b649a43e9aad77c3d4e4a2c5b6997":
        raise ValueError("SwiftNIO 2.105.2 must match the official tag revision")
    if root["swift-http-server"]["revision"] != HTTP_SERVER_SHA:
        raise ValueError("swift-http-server revision unexpectedly changed")
    if root["swift-mcp-server"].get("branch") != "main":
        raise ValueError("Core dependency contract changed; conduct HTTP #14 audit")
    json_version = root["swift-json"].get("version", "")
    try:
        parts = json_version.split(".")
        if len(parts) < 2 or any(not part.isdecimal() for part in parts):
            raise ValueError("invalid version")
        parsed_version = tuple(int(part) for part in parts)
    except (AttributeError, ValueError) as exc:
        raise ValueError(f"Swift-JSON has an invalid semantic version: {json_version!r}") from exc
    if parsed_version < (1, 9, 0):
        raise ValueError("Swift-JSON must meet Core's 1.9.0 minimum")
    print("Release graph consistency passed; Core branch:main remains a 1.0 blocker.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, TypeError, ValueError) as error:
        print(f"Release graph qualification failed: {error}", file=sys.stderr)
        sys.exit(1)
