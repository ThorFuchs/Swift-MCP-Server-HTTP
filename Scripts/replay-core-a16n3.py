#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Read-only replay of the original N3.1 archive; never replace its failed receipt."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys
import tarfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('runner', Path(__file__).with_name('qualify-core-a16n3-referees.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)
ARCHIVE_SHA = 'fcdccd666088a412a98bde53d78170e4741e513164776d7068f8ac22ee47397a'
OLD_RUNNER = '032b78c565c9b42e948c63f1d03dbe280fdd4ff3'


def replay(path):
    r.need(r.digest(path) == ARCHIVE_SHA, 'not the original N3.1 archive')
    with tarfile.open(path, 'r:gz') as archive:
        names = [m.name.removeprefix('./') for m in archive.getmembers() if m.isfile()]
        r.need(len(names) == len(set(names)), 'duplicate archive file')
        def read(name):
            return archive.extractfile('./' + name).read()
        def load(name):
            return json.loads(read(name))
        p = load('provenance.json')
        r.need((p['runner'], p['http'], p['core'], p['upstream']) == (OLD_RUNNER, r.HTTP, r.CORE, r.UPSTREAM), 'source provenance')
        r.need(p['plan'] == [list(x) for x in r.PLAN] and p['node'] == 'v24.22.3' and p['npm'] == '11.19.1' and 'Swift version 6.4.2' in p['swift'] and 'arm64-apple-macosx27.3.0' in p['swift'], 'toolchain or plan mismatch')
        historical = load('results.json')
        r.need(load('summary.json')['exit_code'] == 1 and read('error.txt').strip() == b'one or more legs failed', 'historical failure missing')
        labels = [f'{m}-{n}-{a}' for m, n, a in r.PLAN]
        r.need(historical == [{'leg': label, 'status': 'FAIL', 'error': 'expected 30 unique checks'} for label in labels], 'unexpected historical failure')
        before = load('inputs-before.json')
        r.need(set(before) == set(r.INPUTS) and all(re.fullmatch('[0-9a-f]{64}', h) for h in before.values()), 'invalid input hash map')
        expected = load('expected-pins.json')
        r.need(len(expected) == 29 and expected['swift-mcp-server']['state'] == {'revision': r.CORE}, 'expected graph mismatch')
        for filename, lock in [('root.resolved.json', 'Package.resolved'), ('fixture.resolved.json', r.INPUTS[3])]:
            raw = read(filename)
            pins = json.loads(raw)['pins']
            r.need(len(pins) == 29 and {p['identity']: p for p in pins} == expected, 'pin drift')
            r.need(hashlib.sha256(raw).hexdigest() == before[lock], 'archived lock hash mismatch')
        built = load('artifacts-built.json')
        r.need(built['bundles'] == {'original': r.ORIGINAL, 'candidate': r.CANDIDATE} and set(built['fixtures']) == {'debug', 'release'} and all(re.fullmatch('[0-9a-f]{64}', h) for h in built['fixtures'].values()), 'binary provenance mismatch')
        r.need(load('artifacts-installed.json') == {'bundles': built['bundles'], 'fixtures': {}}, 'installed bundle mismatch')
        for label in ['installed', 'built'] + labels:
            r.need(load(f'inputs-{label}.json') == before, f'input drift: {label}')
            if label != 'installed':
                r.need(load(f'artifacts-{label}.json') == built, f'artifact drift: {label}')
        for label in ['before', 'installed', 'built'] + labels:
            r.need(read(f'verify-{label}.log').strip() == b'PASS: all 29 pins and both actual Core checkouts', f'missing graph receipt: {label}')
        r.need(set(line[3:] for line in read('status.txt').decode().splitlines()) == set(r.INPUTS[:4]), 'unexpected tracked changes')
        builds = {}
        for mode in ('debug', 'release'):
            log = read(f'build-{mode}.log').decode(errors='replace')
            times = re.findall(r'Build complete! \(([0-9.,]+) sec\)', log)
            r.need(len(times) == 1 and not re.search(r'\b(?:warning|error):', log, re.I), f'build receipt: {mode}')
            builds[mode] = float(times[0].replace(',', '.'))
        rows = []
        ids = None
        nonces, pids = set(), set()
        for (mode, _, arm), label in zip(r.PLAN, labels):
            paths = [n for n in names if n.startswith(label + '/results/server-server-stateless-') and n.endswith('/checks.json')]
            r.need(len(paths) == 1, f'missing or duplicate checks: {label}')
            checks = load(paths[0])
            receipt = r.check_receipt(checks, mode, arm)
            if ids is None:
                ids = receipt['ids']
            r.need(ids == receipt['ids'], 'check identity set changed')
            log = read(label + '/referee.log').decode(errors='replace')
            r.need(f"Passed: {receipt['success']}/{receipt['success']}, 0 failed, {len(receipt['warnings'])} warnings" in log, 'referee summary mismatch')
            ready = load(label + '/ready.json')
            r.need(re.fullmatch(r'conformance-[0-9a-f]{32}', ready['nonce']) and ready['nonce'] not in nonces and type(ready['pid']) in (int, float) and ready['pid'] == int(ready['pid']) and ready['pid'] > 0 and ready['pid'] not in pids and ready['protocolVersion'] == '2026-07-28' and re.fullmatch(r'http://127\.0\.0\.1:[0-9]+/mcp', ready['url']), 'invalid/reused readiness receipt')
            nonces.add(ready['nonce']); pids.add(ready['pid'])
            r.need(load(label + '/fixture-exit.json') == {'exit': 0}, 'fixture did not exit 0')
            fixture_log = read(label + '/fixture.stderr').decode(errors='replace')
            r.need(fixture_log.splitlines().count('FIXTURE_STOPPED started=2 joined=2 active=0') == 1, 'missing graceful join')
            mutations = {}
            frames = 0
            for kind in ('prompts', 'tools'):
                target = f'sep-2575-server-sends-{kind}-list-changed-on-subscription'
                matches = [c for c in checks if c['id'] == target]
                r.need(len(matches) == 1, 'missing notification check')
                if matches[0]['status'] == 'SUCCESS':
                    frame = matches[0]['details']['changeFrame']
                    r.need(frame['method'] == f'notifications/{kind}/list_changed' and frame['params']['_meta']['io.modelcontextprotocol/subscriptionId'] is not None, 'invalid notification frame')
                    frames += 1
                measurements = re.findall(r'^FIXTURE_MUTATION kind=' + kind + r' construction_ns=(\d+) preparation_publication_ns=(\d+) notification_admission_ns=(\d+) total_ns=(\d+)$', fixture_log, re.M)
                initial = [tuple(map(int, m)) for m in measurements if int(m[1]) > 0]
                r.need(len(initial) == 1, f'expected one initial {kind} mutation')
                mutations[kind] = initial[0][3]
            rows.append({'leg': label, 'success': receipt['success'], 'warnings': receipt['warnings'], 'frames': frames, 'mutation_total_ns': mutations})
        success = sum(x['success'] for x in rows)
        warnings = sum(len(x['warnings']) for x in rows)
        r.need(success == 178 and warnings == 2 and sum(x['frames'] for x in rows) == 10, 'historical result differs')
        return {'outcome': 'PASS_DIAGNOSTIC_OFFLINE_REPLAY', 'archive_sha256': ARCHIVE_SHA, 'original_runner_exit': 1, 'original_runner': OLD_RUNNER, 'validator_sha256': r.digest(Path(spec.origin)), 'release_gate': 'NOT_EVALUATED', 'success': success, 'warning': warnings, 'failure': 0, 'skipped': 0, 'build_seconds': builds, 'legs': rows, 'limitations': ['No new native execution. Original failure preserved.', 'Binary and non-archived input bytes are attested by recorded hashes, not rehashed.', 'Referee exit inferred from original runner reaching check validation and corroborated by summaries; no separate exit receipt.']}


class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.checks = [{'id': f'ordinary-{i}', 'status': 'SUCCESS'} for i in range(26)] + [{'id': r.PROMPT, 'status': 'SUCCESS'}] + [{'id': r.META_400, 'status': 'SUCCESS', 'details': {'fieldIssue': s}} for s in sorted(r.META_CASES)]

    def warning(self, field='errorMessage', message=r.OBSERVATION_WARNING):
        self.checks[26].update(status='WARNING', **{field: message})

    def reject(self, mode='debug', arm='original'):
        with self.assertRaises(RuntimeError):
            r.check_receipt(self.checks, mode, arm)

    def test_clean(self):
        self.assertEqual(r.check_receipt(self.checks, 'release', 'candidate')['success'], 30)

    def test_known_warning(self):
        self.warning()
        self.assertEqual(r.check_receipt(self.checks, 'debug', 'original')['success'], 29)

    def test_missing_check(self):
        self.checks.pop(); self.reject()

    def test_duplicate_ordinary(self):
        self.checks[0] = copy.deepcopy(self.checks[1]); self.reject()

    def test_duplicate_parameter(self):
        self.checks[-1] = copy.deepcopy(self.checks[-2]); self.reject()

    def test_unknown_parameter(self):
        self.checks[-1]['details']['fieldIssue'] = 'unknown'; self.reject()

    def test_missing_parameter(self):
        self.checks[-1]['details'] = {}; self.reject()

    def test_failure(self):
        self.checks[0]['status'] = 'FAILURE'; self.reject()

    def test_skip(self):
        self.checks[0]['status'] = 'SKIPPED'; self.reject()

    def test_candidate_warning(self):
        self.warning(); self.reject(arm='candidate')

    def test_release_warning(self):
        self.warning(); self.reject(mode='release')

    def test_wrong_warning_message(self):
        self.warning(message='mutation was untestable'); self.reject()

    def test_wrong_warning_field(self):
        self.warning(field='error'); self.reject()

    def test_untestable_warning(self):
        self.warning(); self.checks[26]['details'] = {'untestable': True}; self.reject()

    def test_unrelated_warning(self):
        self.checks[0].update(status='WARNING', errorMessage=r.OBSERVATION_WARNING); self.reject()


if __name__ == '__main__':
    if sys.argv[1:] == ['--self-test']:
        unittest.main(argv=[sys.argv[0]], verbosity=2)
    elif len(sys.argv) == 2:
        print(json.dumps(replay(Path(sys.argv[1])), indent=2, sort_keys=True))
    else:
        sys.exit('usage: replay-core-a16n3.py ARCHIVE | --self-test')
