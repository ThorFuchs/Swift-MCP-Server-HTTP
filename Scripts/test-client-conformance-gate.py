#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline negative controls for the client coverage and receipt gate."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('gate', Path(__file__).with_name('client-conformance-gate.py'))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class GateTests(unittest.TestCase):
    def reference(self):
        records = ''.join(f'  - scenario: {name}\n    leg: client\n    reason: extension\n' for name in sorted(gate.A6))
        return ('server:\n  - server-stateless\nclient:\n  - tools_call\n  - auth/basic-cimd\nnot_scored:\n'
                + records + f'  - scenario: {gate.SCHEMA}\n    leg: client\n    reason: added-after-release\n').encode()

    def parse(self, data):
        with patch.object(gate, 'REFERENCE_BLOB', gate.blob_id(data)):
            return gate.parse_reference(data)

    def test_selection_and_classification(self):
        p = self.parse(self.reference())
        self.assertEqual(p['required'], ['tools_call', 'auth/basic-cimd'])
        self.assertEqual(p['additional'], [gate.SCHEMA])
        self.assertEqual(p['extensions'], list(gate.SKILLS))
        self.assertEqual(set(p['unsupported_a6']), gate.A6)

    def test_reject_changed_reference(self):
        with self.assertRaisesRegex(ValueError, 'blob mismatch'):
            gate.parse_reference(self.reference())

    def test_reject_duplicate_required(self):
        with self.assertRaisesRegex(ValueError, 'duplicate required'):
            self.parse(self.reference().replace(b'  - tools_call\n', b'  - tools_call\n  - tools_call\n'))

    def test_reject_required_extension_overlap(self):
        with self.assertRaisesRegex(ValueError, 'overlap'):
            self.parse(self.reference().replace(b'  - tools_call\n', b'  - ' + gate.SCHEMA.encode() + b'\n'))

    def test_reject_changed_a6_classification(self):
        with self.assertRaisesRegex(ValueError, 'A6'):
            self.parse(self.reference().replace(b'reason: extension', b'reason: pending', 1))

    def receipt(self, statuses, summary='Passed: 2/2, 0 failed, 0 warnings', rc=0, start='tools_call', overall='✅ OVERALL: PASSED', copies=1):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp) / 'result'
            directory.mkdir()
            for i in range(copies):
                case = directory / str(i)
                case.mkdir()
                (case / 'checks.json').write_text(json.dumps([{'status': s} for s in statuses]))
            log = Path(temp) / 'scenario.log'
            log.write_text(f'Starting scenario: {start}\n{summary}\n{overall}\n')
            return gate.inspect_case('tools_call', directory, log, rc)

    def test_valid_receipt_preserves_skips(self):
        counts = self.receipt(['SUCCESS', 'SUCCESS', 'SKIPPED', 'INFO'])
        self.assertEqual(counts, {'SUCCESS': 2, 'FAILURE': 0, 'WARNING': 0, 'SKIPPED': 1, 'INFO': 1})

    def test_reject_empty_or_zero_success(self):
        for statuses in ([], ['SKIPPED', 'INFO']):
            with self.subTest(statuses=statuses), self.assertRaises(ValueError):
                self.receipt(statuses, 'Passed: 0/0, 0 failed, 0 warnings')

    def test_reject_failures_warnings_unknown_status(self):
        for status in ('FAILURE', 'WARNING', 'BOGUS'):
            with self.subTest(status=status), self.assertRaises(ValueError):
                self.receipt(['SUCCESS', 'SUCCESS', status])

    def test_reject_missing_or_duplicate_receipt(self):
        for copies in (0, 2):
            with self.subTest(copies=copies), self.assertRaisesRegex(ValueError, 'raw checks receipt'):
                self.receipt(['SUCCESS', 'SUCCESS'], copies=copies)

    def test_reject_wrong_scenario_or_failed_disposition(self):
        with self.assertRaisesRegex(ValueError, 'scenario start'):
            self.receipt(['SUCCESS', 'SUCCESS'], start='other')
        with self.assertRaisesRegex(ValueError, 'successful referee disposition'):
            self.receipt(['SUCCESS', 'SUCCESS'], overall='❌ OVERALL: FAILED')

    def test_reject_cli_raw_disagreement(self):
        with self.assertRaisesRegex(ValueError, 'summary/raw mismatch'):
            self.receipt(['SUCCESS'], 'Passed: 2/2, 0 failed, 0 warnings')

    def test_reject_nonzero_exit(self):
        with self.assertRaisesRegex(ValueError, 'referee exit'):
            self.receipt(['SUCCESS', 'SUCCESS'], rc=1)


if __name__ == '__main__':
    unittest.main()
