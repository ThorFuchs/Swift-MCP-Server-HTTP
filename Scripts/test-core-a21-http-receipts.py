#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Synthetic controls only; do not run native builds or referees."""
import copy
from pathlib import Path
import runpy
import unittest

runner = runpy.run_path(str(Path(__file__).with_name('qualify-core-a21-http.py')))
audit = runner['audit_records']
S = {'status': 'SUCCESS'}
SKIP = {'status': 'SKIPPED'}
WARN = {'id': runner['PROMPT'], 'status': 'WARNING', 'errorMessage': runner['WARNING']}


def server():
    rows = [('server-stateless', [S]*29+[WARN]), ('tasks-status-notifications', [SKIP])]
    rows += [(str(i), [S]) for i in range(51)]
    rows[-1][1].extend([S]*(241-29-51))
    return copy.deepcopy(rows)


def client():
    rows = [('http-standard-headers', [S]+[dict(SKIP, errorMessage=
             f'Client did not send a {m} request; Mcp-Method header was not exercised for this method.')
             for m in ('initialize', 'notifications/initialized')])]
    rows += [(str(i), [S]) for i in range(36)]
    rows[-1][1].extend([S]*(399-37))
    return copy.deepcopy(rows)


class ReceiptControls(unittest.TestCase):
    def test_debug_server_expected_warning(self):
        self.assertEqual(audit(server(), 'debug', 'server')['counts']['WARNING'], 1)

    def test_clean_release_server(self):
        rows = server(); rows[0][1][-1] = S
        self.assertEqual(audit(rows, 'release', 'server')['counts']['SUCCESS'], 242)

    def test_client_expected_skips(self):
        self.assertEqual(audit(client(), 'release', 'client')['counts']['SUCCESS'], 399)

    def test_warning_in_release(self):
        with self.assertRaises(RuntimeError): audit(server(), 'release', 'server')

    def test_missing_server(self):
        with self.assertRaises(RuntimeError): audit(server()[:-1], 'debug', 'server')

    def test_duplicate_server(self):
        rows = server(); rows[-1] = rows[-2]
        with self.assertRaises(RuntimeError): audit(rows, 'debug', 'server')

    def test_missing_client(self):
        with self.assertRaises(RuntimeError): audit(client()[:-1], 'debug', 'client')

    def test_failure(self):
        rows = server(); rows[0][1][-1] = {'status': 'FAILURE'}
        with self.assertRaises(RuntimeError): audit(rows, 'debug', 'server')

    def test_wrong_warning(self):
        rows = server(); rows[0][1][-1]['errorMessage'] = 'other'
        with self.assertRaises(RuntimeError): audit(rows, 'debug', 'server')

    def test_untestable_warning(self):
        rows = server(); rows[0][1][-1]['details'] = {'untestable': True}
        with self.assertRaises(RuntimeError): audit(rows, 'debug', 'server')

    def test_wrong_skip(self):
        rows = client(); rows[0][1][1]['errorMessage'] = 'unexpected'
        with self.assertRaises(RuntimeError): audit(rows, 'debug', 'client')


if __name__ == '__main__':
    unittest.main(verbosity=2)
