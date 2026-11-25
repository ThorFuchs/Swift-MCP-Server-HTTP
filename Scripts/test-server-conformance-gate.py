#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline controls for the server gate; no Swift or network required."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('conformance_summary.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def check(status='SUCCESS', identifier='check'):
    return {'id': identifier, 'status': status}


class ServerGateTests(unittest.TestCase):
    def setUp(self):
        self.plan = gate.server_plan(dict(core_revision='a' * 40, reference_blob='b' * 40,
            spec_version='2026-07-28', server_required=['server-stateless', 'tools-list'],
            server_tasks=['tasks-lifecycle', gate.TASK_SKIP], server_pending=['json-schema-2020-12']))
        self.raw = {n: [check()] for n in self.plan['required'] + self.plan['tasks'] + self.plan['pending']}
        self.raw[gate.TASK_SKIP] = [dict(check('SKIPPED', gate.TASK_SKIP), errorMessage=gate.SKIP_REASON)]
        self.skills = {n: [check()] for n in self.plan['skills']}
        self.exits = dict.fromkeys(self.skills, 0)

    def suite(self):
        rows = [f'=== Running scenario: {n} ===' for n in self.raw]
        rows.append('=== SUMMARY ===')
        sums = {n: gate.counts(c) for n, c in self.raw.items()}
        for n, c in sums.items():
            rows.append(f"{'✗' if c['FAILURE'] else '✓'} {n}: {c['SUCCESS']} passed, {c['FAILURE']} failed")
        rows.append(f"Total: {sum(c['SUCCESS'] for c in sums.values())} passed, {sum(c['FAILURE'] for c in sums.values())} failed")
        optional = self.plan['tasks'] + self.plan['pending']
        failed = sum(sums[n]['FAILURE'] > 0 for n in optional)
        rows.append(f'Not scored for 2026-07-28: {len(optional)} scenario(s) run, {failed} failing. These do not affect conformance.')
        for n in optional:
            rows.append(f"  {'✗' if sums[n]['FAILURE'] else '✓'} {n} ({'extension' if n in self.plan['tasks'] else 'pending'})")
        return '\n'.join(rows) + '\n'

    def logs(self):
        logs = {}
        for n, c in self.skills.items():
            counts = gate.counts(c)
            s, f, w = (counts[k] for k in ('SUCCESS', 'FAILURE', 'WARNING'))
            logs[n] = f"Running client scenario '{n}' against server: http://localhost/mcp\nPassed: {s}/{s+f}, {f} failed, {w} warnings\n"
        return logs

    def evaluate(self, stdout=None, logs=None, suite_exit=0):
        return gate.evaluate(self.plan, self.raw, self.skills, self.suite() if stdout is None else stdout,
                             self.logs() if logs is None else logs, suite_exit, self.exits)

    def test_valid_and_skip_not_pass(self):
        cases = self.evaluate()
        results = {c['scenario']: c['outcome'] for c in cases}
        self.assertEqual(results[gate.TASK_SKIP], 'KNOWN_UPSTREAM_SKIP')
        self.assertEqual(results['tasks-lifecycle'], 'PASS')
        self.assertEqual(results['json-schema-2020-12'], 'DIAGNOSTIC_PASS')

    def test_required_warning_preserved(self):
        self.raw['server-stateless'].append(check('WARNING', 'should-warning'))
        case = self.evaluate()[0]
        self.assertEqual(case['outcome'], 'PASS_WITH_WARNING')
        self.assertEqual(case['warnings'], ['should-warning'])

    def test_pending_failure_non_scored(self):
        self.raw['json-schema-2020-12'] = [check('FAILURE')]
        case = next(c for c in self.evaluate() if c['category'] == 'pending')
        self.assertEqual(case['outcome'], 'DIAGNOSTIC_FAILURE')

    def test_nonzero_suite_exit_fails_even_if_raw_passes(self):
        with self.assertRaisesRegex(ValueError, 'requirements referee exit'):
            self.evaluate(suite_exit=1)

    def test_nonzero_skill_exit(self):
        self.exits[self.plan['skills'][0]] = 1
        with self.assertRaisesRegex(ValueError, 'referee exit'):
            self.evaluate()

    def test_required_failure(self):
        self.raw['server-stateless'] = [check('FAILURE')]
        with self.assertRaisesRegex(ValueError, 'failed executed checks'):
            self.evaluate()

    def test_tasks_failure(self):
        self.raw['tasks-lifecycle'] = [check('FAILURE')]
        with self.assertRaisesRegex(ValueError, 'failed executed checks'):
            self.evaluate()

    def test_empty_or_unexecuted_case(self):
        for checks in ([], [check('INFO')], [check('WARNING')]):
            with self.subTest(checks=checks), self.assertRaisesRegex(ValueError, 'no executed checks'):
                gate.classify('tools-list', 'required', checks)

    def test_unexpected_skip(self):
        self.raw['tools-list'].append(check('SKIPPED'))
        with self.assertRaisesRegex(ValueError, 'unexpected skipped check'):
            self.evaluate()

    def test_changed_skip_reason(self):
        self.raw[gate.TASK_SKIP][0]['errorMessage'] = 'different skip'
        with self.assertRaisesRegex(ValueError, 'unexpected Tasks skip receipt'):
            self.evaluate()

    def test_future_executed_task_pass_is_not_skip(self):
        self.raw[gate.TASK_SKIP] = [check()]
        self.assertEqual(next(c for c in self.evaluate() if c['scenario'] == gate.TASK_SKIP)['outcome'], 'PASS')

    def test_missing_scenario(self):
        stdout = self.suite()
        self.raw.pop('tools-list')
        with self.assertRaisesRegex(ValueError, 'scenario-set mismatch'):
            self.evaluate(stdout)

    def test_duplicate_start(self):
        with self.assertRaisesRegex(ValueError, 'start-set mismatch'):
            self.evaluate(self.suite() + '=== Running scenario: tools-list ===\n')

    def test_duplicate_summary(self):
        with self.assertRaisesRegex(ValueError, 'duplicate suite summary'):
            self.evaluate(self.suite() + '✓ tools-list: 1 passed, 0 failed\n')

    def test_summary_disagreement(self):
        with self.assertRaisesRegex(ValueError, 'summary/raw mismatch'):
            self.evaluate(self.suite().replace('tools-list: 1 passed', 'tools-list: 2 passed'))

    def test_total_disagreement(self):
        with self.assertRaisesRegex(ValueError, 'suite totals mismatch'):
            self.evaluate(self.suite().replace('Total: 4 passed', 'Total: 5 passed'))

    def test_wrong_not_scored_classification(self):
        with self.assertRaisesRegex(ValueError, 'classification mismatch'):
            self.evaluate(self.suite().replace('tasks-lifecycle (extension)', 'tasks-lifecycle (pending)'))

    def test_skill_summary_disagreement(self):
        logs = self.logs()
        name = self.plan['skills'][0]
        logs[name] = logs[name].replace('1/1', '2/2')
        with self.assertRaisesRegex(ValueError, 'skill summary/raw mismatch'):
            self.evaluate(logs=logs)

    def test_overlapping_plan(self):
        with self.assertRaisesRegex(ValueError, 'duplicate/overlapping'):
            gate.server_plan(dict(core_revision='a'*40, reference_blob='b'*40, spec_version='2026-07-28',
                server_required=['tools-list'], server_tasks=[gate.TASK_SKIP], server_pending=['tools-list']))

    def test_receipt_validation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / 'server-tools-list-2026-11-25T10-36-14-949Z'
            p.mkdir()
            f = p / 'checks.json'
            f.write_text(json.dumps([check()]))
            self.assertEqual(gate.receipts(root, ['tools-list']), {'tools-list': [check()]})
            for value in ([], {}, [check('BOGUS')], [{'status': 'SUCCESS'}]):
                f.write_text(json.dumps(value))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    gate.receipts(root, ['tools-list'])
            f.write_text(json.dumps([check()]))
            with self.assertRaisesRegex(ValueError, 'missing scenarios'):
                gate.receipts(root, ['tools-list', 'server-stateless'])
            with self.assertRaisesRegex(ValueError, 'unknown/duplicate'):
                gate.receipts(root, ['server-stateless'])
            q = root / 'server-tools-list-2026-11-25T10-36-15-949Z'
            q.mkdir()
            (q / 'checks.json').write_text(f.read_text())
            with self.assertRaisesRegex(ValueError, 'unknown/duplicate'):
                gate.receipts(root, ['tools-list'])


if __name__ == '__main__':
    unittest.main()
