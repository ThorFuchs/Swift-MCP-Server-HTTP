#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""N3.1: one locked native Swift fixture, two exact referee bundles; diagnostic only."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

HTTP = 'c99b65a9ee7879187e6d67e9771b8daa30115502'
CORE = '044e2ab332d9f55632c900c13f23502acd8e8972'
UPSTREAM = 'b0fa91d7cef7d844e35a5526e2c9a7549e25dd83'
ORIGINAL = 'b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0'
CANDIDATE = '0d65ec7ba15f0f9a7f977cc7bec612f1592166287fcb57f1ae3cd83c46e23236'
PROMPT = 'sep-2575-server-sends-prompts-list-changed-on-subscription'
INPUTS = ('Package.swift', 'Package.resolved',
          'Tools/Conformance/SwiftFixture/Package.swift',
          'Tools/Conformance/SwiftFixture/Package.resolved',
          'Tools/Conformance/package.json', 'Tools/Conformance/package-lock.json',
          'Tools/Conformance/.nvmrc', 'Tools/Conformance/.npmrc')
PLAN = (('debug', 1, 'original'), ('debug', 1, 'candidate'),
        ('debug', 2, 'candidate'), ('debug', 2, 'original'),
        ('release', 1, 'original'), ('release', 1, 'candidate'))


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def digest(path):
    with path.open('rb') as f:
        h = hashlib.sha256()
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
        return h.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def capture(args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=30).strip()


def stop(proc, grace=15):
    if proc.poll() is not None:
        return proc.returncode
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return proc.wait(timeout=5)
    try:
        return proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)
        raise RuntimeError('process failed to join after SIGTERM; SIGKILL required')


def run(args, cwd, log, timeout):
    with log.open('wb') as f:
        proc = subprocess.Popen(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT,
                                start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            stop(proc)
            raise RuntimeError(f'host watchdog expired: {log.name}')
        except BaseException:
            stop(proc)
            raise
    need(rc == 0, f'exit {rc}: {log.name}')


def raw_receipt(leg, mode, arm):
    paths = list((leg / 'results').rglob('checks.json'))
    need(len(paths) == 1 and paths[0].parent.name.startswith('server-server-stateless-'),
         'expected one stateless receipt')
    checks = json.loads(paths[0].read_text())
    ids = [c['id'] for c in checks]
    need(len(ids) == len(set(ids)) == 30, 'expected 30 unique checks')
    warnings = [c for c in checks if c['status'] == 'WARNING']
    need(all(c['status'] in ('SUCCESS', 'WARNING') for c in checks), 'failed/skipped/unknown check')
    if warnings:
        need(mode == 'debug' and arm == 'original' and [c['id'] for c in warnings] == [PROMPT],
             'unexpected warning')
        need('no notifications/prompts/list_changed arrived' in warnings[0].get('error', ''),
             'not the reproduced observation warning')
    return {'ids': sorted(ids), 'success': 30-len(warnings), 'warnings': [c['id'] for c in warnings]}


def case(checkout, fixture, node, bundle, leg):
    nonce = 'conformance-' + uuid.uuid4().hex
    ready = leg / 'ready.json'
    proc = None
    exit_code = None
    with (leg / 'fixture.stdout').open('wb') as stdout, (leg / 'fixture.stderr').open('wb') as stderr:
        try:
            proc = subprocess.Popen([str(fixture), '--host', '127.0.0.1', '--port', '0',
                                     '--ready-file', str(ready), '--nonce', nonce], cwd=checkout,
                                    stdout=stdout, stderr=stderr, start_new_session=True)
            end = time.monotonic() + 60
            while not ready.exists() or not ready.stat().st_size:
                need(proc.poll() is None and time.monotonic() < end, 'fixture readiness failed')
                time.sleep(0.1)
            data = json.loads(ready.read_text())
            need(data['nonce'] == nonce and re.fullmatch(r'http://127\.0\.0\.1:[0-9]+(?:/[^\s]*)?', data['url']),
                 'invalid ready receipt')
            run([node, str(bundle), 'server', '--url', data['url'], '--scenario', 'server-stateless',
                 '--spec-version', '2026-07-28', '--output-dir', str(leg / 'results'), '--timeout', '90000'],
                checkout, leg / 'referee.log', 120)
        finally:
            if proc is not None:
                try:
                    exit_code = stop(proc)
                finally:
                    write_json(leg / 'fixture-exit.json', {'exit': proc.poll()})
    need(exit_code == 0, f'fixture exit {exit_code}')


def qualify(root, runner, candidate_root, out, work):
    checkout = work / 'http'
    checker = root / 'Scripts/check-core-a16n-notifications.py'
    os.environ['LC_ALL'] = 'C'
    node = shutil.which('node')
    need(node and capture(['node', '-p', 'process.versions.node'], root) == '24.22.3', 'use Node 24.22.3')
    need(capture(['npm', '--version'], root) == '11.19.1', 'use npm 11.19.1')
    need(capture(['uname', '-sm'], root) == 'Darwin arm64', 'native macOS ARM64 required')
    swift = capture(['swift', '--version'], root)
    need(re.search(r'Swift version 6\.4\.2(?:\s|$)', swift), 'use Swift 6.4.2')
    need(capture(['git', 'rev-parse', 'HEAD'], candidate_root) == UPSTREAM, 'wrong upstream commit')
    need(not capture(['git', 'status', '--porcelain', '--untracked-files=no'], candidate_root), 'dirty upstream tracked sources')
    source_bundle = candidate_root / 'dist/index.js'
    need(digest(source_bundle) == CANDIDATE, 'candidate bundle is not the previously qualified artifact')
    os.environ['SDKROOT'] = capture(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], root)
    write_json(out / 'provenance.json', {'runner': runner, 'http': HTTP, 'core': CORE,
               'upstream': UPSTREAM, 'swift': swift, 'os': capture(['sw_vers'], root),
               'cpu': capture(['sysctl', '-n', 'hw.ncpu'], root), 'node': capture(['node', '--version'], root),
               'npm': capture(['npm', '--version'], root), 'plan': PLAN})
    run(['git', 'clone', '--no-hardlinks', '--no-checkout', str(root), str(checkout)], root, out/'clone.log', 120)
    run(['git', 'checkout', '--detach', HTTP], checkout, out/'checkout.log', 60)
    need(capture(['git', 'rev-parse', 'HEAD'], checkout) == HTTP, 'wrong HTTP fixture')
    need(not capture(['git', 'status', '--porcelain'], checkout), 'dirty HTTP fixture')
    run([sys.executable, '-I', str(checker), 'seed', CORE, str(out)], checkout, out/'seed.log', 30)
    for label, args in [('root', ['swift', 'package', 'resolve']),
                        ('fixture', ['swift', 'package', '--package-path', 'Tools/Conformance/SwiftFixture', 'resolve'])]:
        run(args, checkout, out/f'resolve-{label}.log', 900)
    def verify(label):
        run([sys.executable, '-I', str(checker), 'verify', str(out)], checkout, out/f'verify-{label}.log', 30)
    verify('before')
    before = {p: digest(checkout/p) for p in INPUTS}
    write_json(out/'inputs-before.json', before)
    npm_root = checkout/'Tools/Conformance'
    run(['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], npm_root, out/'npm.log', 900)
    package = npm_root/'node_modules/@modelcontextprotocol/conformance'
    need(json.loads((package/'package.json').read_text())['version'] == '0.2.0-alpha.12', 'wrong official version')
    original = package/'dist/index.js'
    candidate = package/'dist/index.n3-candidate.js'
    need(not candidate.exists(), 'unexpected candidate path')
    shutil.copyfile(source_bundle, candidate)  # same runtime deps and requirements; never overwrite original
    bundles = {'original': original, 'candidate': candidate}
    expected = {'original': ORIGINAL, 'candidate': CANDIDATE}
    fixtures = {}
    hashes = {}
    def integrity(label):
        now = {p: digest(checkout/p) for p in INPUTS}
        write_json(out/f'inputs-{label}.json', now)
        need(now == before, f'input drift: {label}')
        actual = {k: digest(v) for k, v in bundles.items()}
        need(actual == expected and digest(source_bundle) == CANDIDATE, f'bundle drift: {label}')
        need(all(digest(p) == hashes[k] for k, p in fixtures.items()), f'fixture drift: {label}')
        write_json(out/f'artifacts-{label}.json', {'bundles': actual, 'fixtures': hashes})
        verify(label)
    integrity('installed')
    for mode in ('debug', 'release'):
        args = ['swift', 'build', '--force-resolved-versions', '-c', mode, '-j', '2',
                '--package-path', 'Tools/Conformance/SwiftFixture']
        run(args+['--product', 'SwiftConformanceServer'], checkout, out/f'build-{mode}.log', 1800)
        fixture = Path(capture(args+['--show-bin-path'], checkout))/'SwiftConformanceServer'
        need(fixture.is_file() and os.access(fixture, os.X_OK), 'missing fixture executable')
        fixtures[mode] = fixture
        hashes[mode] = digest(fixture)
    integrity('built')
    results = []
    ids = None
    for mode, round_no, arm in PLAN:
        label = f'{mode}-{round_no}-{arm}'
        leg = out/label
        leg.mkdir()
        row = {'leg': label, 'status': 'FAIL'}
        try:
            case(checkout, fixtures[mode], node, bundles[arm], leg)
            receipt = raw_receipt(leg, mode, arm)
            run([sys.executable, '-I', str(checker), 'receipt',
                 'baseline' if arm == 'original' else 'candidate', str(leg)], checkout, leg/'receipt.log', 30)
            if ids is None:
                ids = receipt['ids']
            need(receipt['ids'] == ids, 'check ID set changed across legs')
            row.update(receipt, status='PASS')
        except Exception as exc:
            row['error'] = str(exc)
        finally:
            results.append(row)
            write_json(out/'results.json', results)
            print(label, row['status'], row.get('success'), row.get('error', ''), flush=True)
        integrity(label)
    status = subprocess.check_output(['git', 'status', '--porcelain'], cwd=checkout, text=True, timeout=30).rstrip('\n')
    (out/'status.txt').write_text(status+'\n')
    need(set(line[3:] for line in status.splitlines()) == set(INPUTS[:4]), 'unexpected checkout changes')
    need(all(r['status'] == 'PASS' for r in results), 'one or more legs failed')
    reproduced = any(r['warnings'] for r in results)
    outcome = 'PASS_DIAGNOSTIC' if reproduced else 'INCONCLUSIVE_NO_ORIGINAL_WARNING'
    write_json(out/'decision.json', {'outcome': outcome, 'official_referee_unchanged': True,
                                     'release_gate': 'NOT_EVALUATED', 'legs': results})
    return 0 if reproduced else 2


def main():
    root = Path(__file__).resolve().parents[1]
    need(len(sys.argv) == 4, 'usage: script RUNNER_SHA EVIDENCE_DIR CANDIDATE_CHECKOUT')
    runner, destination, upstream = sys.argv[1:]
    need(re.fullmatch(r'[0-9a-f]{40}', runner) and capture(['git', 'rev-parse', 'HEAD'], root) == runner,
         'exact runner SHA required')
    need(not capture(['git', 'status', '--porcelain'], root), 'dirty runner')
    dest = Path(destination).expanduser().resolve()
    need(dest != root and root not in dest.parents, 'evidence must be outside runner checkout')
    dest.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='core-a16n3-', dir=dest))
    work = Path(tempfile.mkdtemp(prefix='core-a16n3-work-', dir=dest))
    rc = 1
    try:
        rc = qualify(root, runner, Path(upstream).expanduser().resolve(), out, work)
    except Exception as exc:
        (out/'error.txt').write_text(str(exc)+'\n')
        print('FAIL:', exc, file=sys.stderr)
    finally:
        write_json(out/'summary.json', {'exit_code': rc, 'work': str(work)})
        archive = Path(str(out)+'.tar.gz')
        with tarfile.open(archive, 'w:gz') as tar:
            tar.add(out, arcname='.')
        print(f'ARCHIVE: {archive} (exit {rc})', flush=True)
    return rc


if __name__ == '__main__':
    sys.exit(main())
