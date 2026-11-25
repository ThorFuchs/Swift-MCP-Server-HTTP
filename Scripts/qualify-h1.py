#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Native H1 evidence; only the disposable checkout's two locks may change."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile
import tempfile

BASE = 'd2e4cb5a07b4f2453ccd8106d799ca548470c202'
NIO = 'b003027fc38b649a43e9aad77c3d4e4a2c5b6997'
OLD_NIO = '2f58d8ef84438d6517fc78bcea2f8527e3c72936'
LOCKS = (Path('Package.resolved'), Path('Tools/Conformance/SwiftFixture/Package.resolved'))
CASES = ('nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion',
         'nativeHTTPRepeatedFINReleasesOwnersAndRecovers',
         'nativeTLSPeerProcessExitCancelsBeforeResponseHead')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def capture(root, *args):
    return subprocess.check_output(args, cwd=root, text=True, timeout=60).strip()


def pinmap(data):
    require(data['version'] == 3, 'unexpected lock format')
    entries = {p['identity']: p for p in data['pins']}
    require(len(entries) == len(data['pins']), 'duplicate lock pin')
    return entries


def expected_pins(data):
    pins = pinmap(data)
    nio = pins['swift-nio']
    require(nio['state'] == {'revision': OLD_NIO, 'version': '2.105.0'}, 'wrong H1 baseline')
    nio['state'] = {'revision': NIO, 'version': '2.105.2'}
    return pins


def validate_lock(data, expected):
    actual = pinmap(data)
    require(actual == expected, 'unrelated pin drift or wrong NIO release')
    # SwiftPM v3 allows absent originHash. Successful resolve can leave a seed
    # lock byte-identical (native Swift 6.4.2 receipt 540jshab). A hash is
    # metadata, not proof of the actual resolved source revisions.
    origin = data.get('originHash')
    if 'originHash' in data:
        require(isinstance(origin, str) and re.fullmatch('[0-9a-f]{64}', origin),
                'invalid SwiftPM origin hash')
    return origin


def check(root, expected, resolved):
    receipt = {}
    for lock, pins in zip(LOCKS, expected):
        origin = validate_lock(json.loads((root / lock).read_text()), pins)
        entry = {'originHash': origin, 'pin_count': len(pins), 'checkout_heads': {}}
        if resolved:
            checkouts = root / lock.parent / '.build' / 'checkouts'
            require(checkouts.is_dir(), f'missing checkout directory: {checkouts}')
            children = list(checkouts.iterdir())
            for identity, pin in sorted(pins.items()):
                require(pin['kind'] == 'remoteSourceControl', f'unexpected pin kind: {identity}')
                matches = [p for p in children if p.name.lower() == identity.lower()]
                require(len(matches) == 1, f'{checkouts}: missing/ambiguous {identity}')
                actual = capture(matches[0], 'git', 'rev-parse', '--verify', 'HEAD')
                require(actual == pin['state']['revision'], f'{lock}: {identity} checkout drift')
                entry['checkout_heads'][identity] = actual
        receipt[str(lock)] = entry
    changed = set(capture(root, 'git', 'diff', '--name-only', 'HEAD').splitlines())
    require(changed <= {str(p) for p in LOCKS}, 'unexpected tracked file changes')
    return receipt


def run(root, out, label, *args, env=None):
    print(f'=== {label} ===', flush=True)
    log = out / f'{label}.log'
    with log.open('w', encoding='utf-8') as f:
        p = subprocess.Popen(args, cwd=root, env=env, stdout=subprocess.PIPE,
                             stderr=subprocess.STDOUT, text=True, errors='replace')
        try:
            for line in p.stdout:
                f.write(line)
                print(line, end='', flush=True)
            rc = p.wait()
        except BaseException:
            if p.poll() is None:
                p.terminate()
                p.wait()
            raise
    require(rc == 0, f'{label}: exit {rc}')
    return log


def qualify(root, out, sha, mode, stages):
    require(capture(root, 'git', 'rev-parse', 'HEAD') == sha, 'wrong HTTP source')
    require(not capture(root, 'git', 'status', '--porcelain'), 'checkout must start clean')
    require(capture(root, 'uname', '-sm') == 'Darwin arm64', 'native ARM64 macOS required')
    require(int(capture(root, 'sw_vers', '-productVersion').split('.')[0]) >= 27, 'macOS 27+ required')
    swift = capture(root, 'swift', '--version')
    require(re.search(r'Swift version 6\.4\.2(?:\s|$)', swift), 'Swift 6.4.2 required')
    os.environ['SDKROOT'] = capture(root, 'xcrun', '--sdk', 'macosx', '--show-sdk-path')
    (out / 'provenance.json').write_text(json.dumps({'source': sha, 'baseline': BASE,
        'nio': NIO, 'swift': swift, 'macOS': capture(root, 'sw_vers'),
        'xcode': capture(root, 'xcodebuild', '-version'), 'mode': mode}, indent=2) + '\n')
    expected = [expected_pins(json.loads(capture(root, 'git', 'show', f'{BASE}:{lock}'))) for lock in LOCKS]
    check(root, expected, False)

    def record_graph(label):
        receipt = check(root, expected, True)
        (out / f'graph-{label}.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')

    def stage(label, *args, env=None):
        log = run(root, out, label, *args, env=env)
        record_graph(label)
        stages.append(label)
        (out / 'passed-stages.json').write_text(json.dumps(stages, indent=2) + '\n')
        return log

    # SwiftPM owns optional origin hashes. Refuse any re-resolution of Core or other pins.
    run(root, out, 'resolve-root', 'swift', 'package', 'resolve')
    run(root, out, 'resolve-fixture', 'swift', 'package', '--package-path', str(LOCKS[1].parent), 'resolve')
    stage('graph', sys.executable, '-I', 'Scripts/check-release-graph.py', *map(str, LOCKS))
    for configuration in ('debug', 'release'):
        for case in CASES:
            label = f'{configuration}-{case}'
            log = run(root, out, label, 'swift', 'test', '--force-resolved-versions',
                      '-c', configuration, '-j', '2', '--filter', case)
            content = log.read_text()
            require(f'{case}() passed' in content and 'known issue' not in content.lower(),
                    f'{label}: named unmasked pass not established')
            record_graph(label)
            stages.append(label)
            (out / 'passed-stages.json').write_text(json.dumps(stages, indent=2) + '\n')
    (out / 'focused-PASS.txt').write_text('6/6 named unmasked executions; exact official NIO tag\n')
    if mode == 'full':
        stage('sdk-debug', 'bash', 'Scripts/test.sh', '--force-resolved-versions', '-j', '2')
        for role, script in (('server', 'conformance.sh'), ('client', 'client-conformance.sh')):
            stage(f'debug-{role}', 'bash', f'Scripts/{script}', str(out / f'debug-{role}-results'),
                  env={**os.environ, 'MCP_HTTP_FIXTURE_CONFIGURATION': 'debug'})
        stage('sdk-release', 'bash', 'Scripts/qualify-release.sh', 'full')
        for role, script in (('server', 'conformance.sh'), ('client', 'client-conformance.sh')):
            stage(f'release-{role}', 'bash', f'Scripts/{script}', str(out / f'release-{role}-results'),
                  env={**os.environ, 'MCP_HTTP_FIXTURE_CONFIGURATION': 'release'})
    record_graph('final')


def main():
    root = Path(__file__).resolve().parents[1]
    require(len(sys.argv) == 4, 'usage: qualify-h1.py EXACT_HTTP_SHA EVIDENCE_PARENT focused|full')
    sha, parent_arg, mode = sys.argv[1:]
    require(re.fullmatch('[0-9a-f]{40}', sha) and mode in ('focused', 'full'), 'invalid arguments')
    parent = Path(parent_arg).expanduser().resolve()
    require(parent != root and root not in parent.parents, 'evidence must be outside source checkout')
    parent.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='http-h1-', dir=parent))
    stages, rc = [], 1
    try:
        qualify(root, out, sha, mode, stages)
        rc = 0
    except (Exception, KeyboardInterrupt) as exc:
        (out / 'failure.txt').write_text(f'{type(exc).__name__}: {exc}\n')
        print(f'FAIL: {exc}', file=sys.stderr)
    finally:
        for lock, name in zip(LOCKS, ('root', 'fixture')):
            if (root / lock).is_file():
                (out / f'{name}-resolved.json').write_bytes((root / lock).read_bytes())
        with (out / 'tracked.diff').open('wb') as f:
            subprocess.run(['git', 'diff', 'HEAD', '--', *map(str, LOCKS)], cwd=root, stdout=f, check=False)
        (out / 'decision.json').write_text(json.dumps({'source': sha, 'mode': mode,
            'exit': rc, 'focused_pass': (out / 'focused-PASS.txt').exists(), 'passed': stages,
            'release_gate': 'REVIEW_REQUIRED'}, indent=2) + '\n')
        archive = Path(str(out) + '.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(out, arcname='.')
        print(f'ARCHIVE: {archive} (exit {rc})', flush=True)
    return rc


if __name__ == '__main__':
    sys.exit(main())
