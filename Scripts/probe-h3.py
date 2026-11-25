#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""H3.1 diagnostic: one dependency substitution on a disposable H1 checkout."""
import copy
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

BASE = '2cbedd510b15f510c24373ea45ca4fc9cf754cbe'
OLD = '0b8f1691b83a6cedbe1c15096e6b8d7f485d59a9'
TAG = '3e50d9404eb916cd6d030b81af90fdaec73efebc'
NIO = 'b003027fc38b649a43e9aad77c3d4e4a2c5b6997'
CORE = 'd892bd34add1ad067ae6f286bd74c824486d8c07'
FIXTURE = Path('Tools/Conformance/SwiftFixture')
LOCKS = (Path('Package.resolved'), FIXTURE / 'Package.resolved')
MANIFEST = Path('Package.swift')
ALLOWED = {str(p) for p in (MANIFEST, *LOCKS)}
PRODUCTS = ('SwiftConformanceServer', 'SwiftConformanceClient')
SYMBOL = re.compile(r'type metadata accessor for NIOHTTPServer\.(?:NIOHTTPServer\.)?(Connection\.HTTPProtocol|Reader\.State(?:\.Reading)?)"')


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def capture(cwd, *args):
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=90).strip()


def read_pins(data):
    need(data['version'] == 3, 'wrong lock format')
    pins = {p['identity']: p for p in data['pins']}
    need(len(pins) == len(data['pins']) == 29, 'expected 29 unique pins')
    return pins


def candidate(data):
    result = copy.deepcopy(data)
    pins = read_pins(result)
    need(pins['swift-http-server']['state'] == {'revision': OLD}, 'wrong H1 HTTP-server pin')
    need(pins['swift-nio']['state'] == {'revision': NIO, 'version': '2.105.2'}, 'wrong H1 NIO pin')
    need(pins['swift-mcp-server']['state'] == {'revision': CORE, 'branch': 'main'}, 'wrong H1 Core pin')
    pins['swift-http-server']['state'] = {'revision': TAG, 'version': '0.5.0'}
    result.pop('originHash', None)  # optional; let SwiftPM supply it if needed
    return result


def classify(rc, text):
    if rc == 0:
        return 'build_succeeded', []
    marker = 'Undefined symbols for architecture arm64:'
    symbols = sorted(set(SYMBOL.findall(text[text.index(marker):]))) if marker in text else []
    return ('matching_undefined_metadata' if symbols else 'other_build_failure'), symbols


def run(root, out, label, *args):
    log = out / (label + '.log')
    print('=== ' + label + ' ===', flush=True)
    with log.open('w', encoding='utf-8') as f:
        rc = subprocess.run(args, cwd=root, stdout=f, stderr=subprocess.STDOUT).returncode
    print(f'{label}: exit {rc}', flush=True)
    return rc, log.read_text(errors='replace')


def qualify(root, out, sha, results):
    need(capture(root, 'git', 'rev-parse', 'HEAD') == sha, 'unexpected runner SHA')
    need(not capture(root, 'git', 'status', '--porcelain'), 'start with a clean disposable checkout')
    need(capture(root, 'uname', '-sm') == 'Darwin arm64', 'native macOS ARM64 required')
    need(int(capture(root, 'sw_vers', '-productVersion').split('.')[0]) >= 27, 'macOS 27+ required')
    swift = capture(root, 'swift', '--version')
    need(re.search(r'Swift version 6\.4\.2(?:\s|$)', swift), 'Swift 6.4.2 required')
    need(shutil.disk_usage(root).free >= 20 * 1024**3, 'need at least 20 GiB free for a fresh diagnostic build')
    need(all(not (root / lock.parent / '.build').exists() for lock in LOCKS), 'fresh build directories required')
    changed = set(capture(root, 'git', 'diff', '--name-only', BASE, sha).splitlines())
    need(changed <= {'Scripts/probe-h3.py', 'Docs/Release/H3_HTTP_SERVER_REASSESSMENT.md'}, 'unexpected diagnostic branch delta')
    os.environ['SDKROOT'] = capture(root, 'xcrun', '--sdk', 'macosx', '--show-sdk-path')
    os.environ['GIT_TERMINAL_PROMPT'] = '0'
    (out / 'provenance.json').write_text(json.dumps({'source': sha, 'base': BASE, 'http_server': TAG,
        'backend': 'swiftbuild', 'swift': swift, 'xcode': capture(root, 'xcodebuild', '-version'),
        'os': capture(root, 'sw_vers'), 'free_bytes': shutil.disk_usage(root).free}, indent=2) + '\n')
    original = (root / MANIFEST).read_text()
    needle = f'.package(url: "https://github.com/swift-server/swift-http-server.git", revision: "{OLD}", traits: [])'
    need(original.count(needle) == 1, 'unexpected manifest')
    manifest = original.replace(needle, '.package(url: "https://github.com/swift-server/swift-http-server.git", exact: "0.5.0", traits: [])')
    (root / MANIFEST).write_text(manifest)
    expected = {}
    for lock in LOCKS:
        data = candidate(json.loads((root / lock).read_text()))
        expected[lock] = read_pins(data)
        (root / lock).write_text(json.dumps(data, indent=2) + '\n')

    def integrity(label, resolved):
        receipt = {}
        need((root / MANIFEST).read_text() == manifest, 'manifest drift')
        need(set(capture(root, 'git', 'diff', '--name-only', 'HEAD').splitlines()) <= ALLOWED, 'unexpected source drift')
        for lock, pins in expected.items():
            data = json.loads((root / lock).read_text())
            need(read_pins(data) == pins, f'{lock}: unexpected pin drift')
            if 'originHash' in data:
                need(isinstance(data['originHash'], str) and re.fullmatch('[0-9a-f]{64}', data['originHash']), 'invalid originHash')
            heads = {}
            if resolved:
                checkout = root / lock.parent / '.build/checkouts'
                for name, pin in sorted(pins.items()):
                    matches = [p for p in checkout.iterdir() if p.name.lower() == name.lower()]
                    need(len(matches) == 1, f'{lock}: missing/ambiguous {name}')
                    actual = capture(matches[0], 'git', 'rev-parse', '--verify', 'HEAD')
                    need(actual == pin['state']['revision'], f'{lock}: {name} checkout drift')
                    heads[name] = actual
            receipt[str(lock)] = {'pins': data, 'checkout_heads': heads}
        (out / f'graph-{label}.json').write_text(json.dumps(receipt, indent=2) + '\n')

    integrity('seed', False)
    for label, path in [('root', '.'), ('fixture', str(FIXTURE))]:
        rc, _ = run(root, out, 'resolve-' + label, 'swift', 'package', '--package-path', path, 'resolve')
        need(rc == 0, 'resolution failed: ' + label)
    integrity('resolved', True)
    for product in PRODUCTS:
        args = ('swift', 'build', '--build-system', 'swiftbuild', '--force-resolved-versions',
                '-c', 'release', '-j', '2', '--package-path', str(FIXTURE))
        rc, log = run(root, out, product, *args, '--product', product, '-v')
        status, symbols = classify(rc, log)
        if rc == 0:
            binary = Path(capture(root, *args, '--show-bin-path')) / product
            need(binary.is_file() and os.access(binary, os.X_OK), 'missing executable: ' + product)
            status = 'linked_executable_verified'
        results.append({'product': product, 'exit': rc, 'classification': status, 'symbols': symbols})
        integrity(product, True)
    return 'LINK_PASS_ONLY' if all(r['exit'] == 0 for r in results) else 'LINK_BLOCKED'


def main():
    need(len(sys.argv) == 3 and re.fullmatch('[0-9a-f]{40}', sys.argv[1]), 'usage: probe-h3.py EXACT_SHA EVIDENCE_PARENT')
    root = Path(__file__).resolve().parents[1]
    parent = Path(sys.argv[2]).expanduser().resolve()
    need(parent != root and root not in parent.parents, 'evidence must be outside checkout')
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='http-h3-', dir=parent))
    results, outcome = [], 'SETUP_OR_INTEGRITY_FAILURE'
    try:
        outcome = qualify(root, out, sys.argv[1], results)
    except (Exception, KeyboardInterrupt) as exc:
        (out / 'failure.txt').write_text(f'{type(exc).__name__}: {exc}\n')
        print('FAIL:', exc, file=sys.stderr)
    finally:
        (out / 'decision.json').write_text(json.dumps({'outcome': outcome, 'results': results,
            'release_gate': 'NOT_EVALUATED'}, indent=2) + '\n')
        with tarfile.open(str(out) + '.tar.gz', 'w:gz') as archive:
            archive.add(out, arcname='.')
        print(f'ARCHIVE: {out}.tar.gz ({outcome})', flush=True)
    return 0 if outcome == 'LINK_PASS_ONLY' else 1


if __name__ == '__main__':
    sys.exit(main())
