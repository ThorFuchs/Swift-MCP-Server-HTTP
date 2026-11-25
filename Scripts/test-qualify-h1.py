#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Host-independent tests for the H1 evidence gate (no Swift or network)."""
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('h1', Path(__file__).with_name('qualify-h1.py'))
h1 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h1)


def pin(identity, revision, version):
    return {'identity': identity, 'kind': 'remoteSourceControl',
            'location': f'https://example.invalid/{identity}.git',
            'state': {'revision': revision, 'version': version}}


class GraphTests(unittest.TestCase):
    def setUp(self):
        self.baseline = {'version': 3, 'pins': [
            pin('swift-nio', h1.OLD_NIO, '2.105.0'),
            pin('swift-mcp-server', '1' * 40, '0.1.0'),
            pin('swift-collections', '2' * 40, '1.6.0'),
        ]}
        self.expected = h1.expected_pins(copy.deepcopy(self.baseline))
        self.data = {'version': 3, 'pins': list(copy.deepcopy(self.expected).values())}
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.heads = {}
        self.drift = ''
        for lock in h1.LOCKS:
            path = self.root / lock
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(self.data))
            for name, entry in self.expected.items():
                checkout = path.parent / '.build' / 'checkouts' / name
                checkout.mkdir(parents=True)
                self.heads[checkout] = entry['state']['revision']

    def capture(self, root, *args):
        if args == ('git', 'diff', '--name-only', 'HEAD'):
            return self.drift
        self.assertEqual(args, ('git', 'rev-parse', '--verify', 'HEAD'))
        return self.heads[root]

    def graph(self):
        with patch.object(h1, 'capture', side_effect=self.capture):
            return h1.check(self.root, [self.expected, self.expected], True)

    def test_missing_origin_is_valid(self):
        self.assertIsNone(h1.validate_lock(self.data, self.expected))

    def test_present_origin_is_validated(self):
        self.data['originHash'] = 'a' * 64
        self.assertEqual(h1.validate_lock(self.data, self.expected), 'a' * 64)
        for invalid in ('', 'a' * 63, 'z' * 64, None, 7):
            with self.subTest(invalid=invalid):
                self.data['originHash'] = invalid
                with self.assertRaisesRegex(RuntimeError, 'invalid SwiftPM origin hash'):
                    h1.validate_lock(self.data, self.expected)

    def test_nio_drift(self):
        self.data['pins'][0]['state']['revision'] = h1.OLD_NIO
        with self.assertRaisesRegex(RuntimeError, 'pin drift'):
            h1.validate_lock(self.data, self.expected)

    def test_unrelated_pin_drift(self):
        self.data['pins'][1]['state']['revision'] = '3' * 40
        with self.assertRaisesRegex(RuntimeError, 'pin drift'):
            h1.validate_lock(self.data, self.expected)

    def test_duplicate_pin(self):
        self.data['pins'].append(self.data['pins'][0])
        with self.assertRaisesRegex(RuntimeError, 'duplicate lock pin'):
            h1.validate_lock(self.data, self.expected)

    def test_wrong_lock_format(self):
        self.data['version'] = 2
        with self.assertRaisesRegex(RuntimeError, 'unexpected lock format'):
            h1.validate_lock(self.data, self.expected)

    def test_all_checkout_heads_recorded(self):
        receipt = self.graph()
        for lock in h1.LOCKS:
            self.assertEqual(receipt[str(lock)]['pin_count'], 3)
            self.assertIsNone(receipt[str(lock)]['originHash'])
            self.assertEqual(receipt[str(lock)]['checkout_heads'], {
                k: v['state']['revision'] for k, v in self.expected.items()})

    def test_non_nio_checkout_drift(self):
        path = self.root / h1.LOCKS[1].parent / '.build/checkouts/swift-collections'
        self.heads[path] = '3' * 40
        with self.assertRaisesRegex(RuntimeError, 'swift-collections checkout drift'):
            self.graph()

    def test_missing_checkout(self):
        path = self.root / h1.LOCKS[0].parent / '.build/checkouts/swift-nio'
        path.rmdir()
        with self.assertRaisesRegex(RuntimeError, 'missing/ambiguous swift-nio'):
            self.graph()

    def test_unexpected_tracked_change(self):
        self.drift = 'Sources/MCPHTTP/HTTPTransport.swift'
        with self.assertRaisesRegex(RuntimeError, 'unexpected tracked file changes'):
            self.graph()


if __name__ == '__main__':
    unittest.main()
