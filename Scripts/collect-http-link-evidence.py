#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Retain exact linker diagnostics and the available producer/consumer symbols."""
import json
import pathlib
import re
import shutil
import subprocess
import sys

log, build, output = map(pathlib.Path, sys.argv[1:4])
output.mkdir(parents=True, exist_ok=True)
text = log.read_text(errors="replace")
marker = "Undefined symbols for architecture"
tail = text[text.index(marker):] if marker in text else ""
pattern = re.compile(
    r'type metadata accessor for NIOHTTPServer\.(?:NIOHTTPServer\.)?'
    r'(Connection\.HTTPProtocol|Reader\.State(?:\.Reading)?)"'
)
symbols = sorted(set(pattern.findall(tail)))
summary = {
    "has_undefined_symbol_diagnostic": bool(tail),
    "matching_undefined_metadata": symbols,
    "object_inspection": [],
    "link_file_lists": [],
}
(output / "undefined-metadata.txt").write_text("\n".join(symbols) + ("\n" if symbols else ""))
lines = text.splitlines()
indices = {
    nearby
    for index, line in enumerate(lines)
    if any(token in line for token in ["Undefined symbols", "type metadata accessor", "referenced from:", "ld: symbol(s)", "clang: error"])
    for nearby in range(max(0, index - 1), min(len(lines), index + 9))
}
(output / "linker-excerpts.txt").write_text("\n".join(lines[index] for index in sorted(indices)) + "\n")

if build.exists():
    lists = sorted(build.rglob("*.LinkFileList"))
    list_dir = output / "link-inputs"
    list_dir.mkdir(exist_ok=True)
    for index, source in enumerate(lists):
        target = list_dir / f"{index:03d}-{source.name}"
        shutil.copyfile(source, target)
        summary["link_file_lists"].append({"source": str(source), "copy": str(target.relative_to(output))})

    # Swift Build commonly emits one WMO object per module; native SwiftPM can
    # emit file-specific objects. Retain both shapes without inspecting unrelated
    # dependency objects or copying gigabytes of the build tree into CI artifacts.
    objects = [
        path for path in sorted(build.rglob("*.o"))
        if path.name in {"MCPHTTP.o", "NIOHTTPServer.o", "MCPHTTP.swift.o", "NIOHTTPServer.swift.o"}
        or any(name in path.name for name in ["NIOHTTPServerReader", "NIOHTTPServer+Connection", "HTTPTransport", "HTTPRequestReader"])
    ]
    raw_parts = []
    decoded_parts = []
    relevant_parts = []
    for path in objects:
        heading = f"\nOBJECT: {path}\n"
        try:
            result = subprocess.run(["xcrun", "nm", "-m", str(path)], text=True, capture_output=True, check=False)
            raw_parts.extend([heading, result.stdout, result.stderr])
            item = {"path": str(path), "nm_exit_code": result.returncode}
            if result.returncode == 0:
                demangled = subprocess.run(["xcrun", "swift-demangle"], input=result.stdout, text=True, capture_output=True, check=False)
                item["demangle_exit_code"] = demangled.returncode
                decoded_parts.extend([heading, demangled.stdout, demangled.stderr])
                relevant_parts.append(heading)
                relevant_parts.extend(
                    line + "\n" for line in demangled.stdout.splitlines()
                    if "NIOHTTPServer" in line and ("HTTPProtocol" in line or "Reader.State" in line)
                )
            summary["object_inspection"].append(item)
        except OSError as error:
            summary["object_inspection"].append({"path": str(path), "inspection_error": str(error)})
    (output / "symbols-raw.txt").write_text("".join(raw_parts))
    (output / "symbols-demangled.txt").write_text("".join(decoded_parts))
    (output / "symbols-relevant.txt").write_text("".join(relevant_parts))

(output / "diagnostic.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({"matching_undefined_metadata": symbols, "objects_inspected": len(summary["object_inspection"])}))
