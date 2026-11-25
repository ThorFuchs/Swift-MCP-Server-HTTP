#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Synthetic controls only; do not run native builds or referees."""
import copy
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

runner = runpy.run_path(str(Path(__file__).with_name('qualify-core-a21-http.py')))
audit = runner['audit_records']
INPUTS = runner['INPUTS']
verify_disposable_status = runner['verify_disposable_status']
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


class WorkingTreeControls(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'repo'
        self.root.mkdir()
        self.receipt = Path(self.temp.name) / 'status.txt'
        self.git('init', '-q')
        self.git('config', 'user.name', 'Harness Test')
        self.git('config', 'user.email', 'harness@example.invalid')
        self.git('config', 'commit.gpgsign', 'false')
        for path in INPUTS:
            file = self.root / path
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('original\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        for path in INPUTS[:4]:
            (self.root / path).write_text('seeded\n')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, timeout=60)

    def reject(self):
        with self.assertRaisesRegex(RuntimeError, 'unexpected tracked/untracked changes'):
            verify_disposable_status(self.root, self.receipt)
        self.assertEqual(self.receipt.read_bytes(), self.git('status', '--porcelain=v1', '--untracked-files=all', '--no-renames'))

    def test_four_unstaged_edits_and_old_parser_reproduction(self):
        raw = self.git('status', '--porcelain=v1')
        self.assertTrue(raw.startswith(b' M '))
        old = raw.decode().strip()
        self.assertNotEqual({line[3:] for line in old.splitlines()}, set(INPUTS[:4]))
        verify_disposable_status(self.root, self.receipt)
        self.assertEqual(self.receipt.read_bytes(), raw)

    def test_extra_tracked_edit(self):
        (self.root / INPUTS[4]).write_text('unexpected\n')
        self.reject()

    def test_extra_untracked_path(self):
        extra = self.root / 'extra directory' / 'unexpected.txt'
        extra.parent.mkdir()
        extra.write_text('unexpected\n')
        self.reject()

    def test_missing_expected_edit(self):
        (self.root / INPUTS[0]).write_text('original\n')
        self.reject()

    def test_staged_edit(self):
        self.git('add', INPUTS[0])
        self.reject()

    def test_removed_expected_path(self):
        (self.root / INPUTS[0]).unlink()
        self.reject()

    def test_untracked_config_cannot_hide_file(self):
        self.git('config', 'status.showUntrackedFiles', 'no')
        (self.root / 'unexpected.txt').write_text('unexpected\n')
        self.reject()


if __name__ == '__main__':
    unittest.main(verbosity=2)
