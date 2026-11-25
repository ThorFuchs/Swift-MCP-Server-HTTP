#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline runner and synthetic issuer controls (no Swift dependency build)."""
import base64
import copy
import hashlib
import http.client
import importlib.util
import json
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlencode, urlsplit

spec = importlib.util.spec_from_file_location('consumer', Path(__file__).with_name('qualify-external-consumer.py'))
consumer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(consumer)


def lock():
    names = list(consumer.DIRECT[1:]) + [f'synthetic-{i}' for i in range(24)]
    entries = []
    for i, name in enumerate(names):
        state = {'revision': f'{i:040x}', 'version': '1.2.3'}
        if name == 'swift-mcp-server':
            state = {'revision': f'{i:040x}', 'branch': 'main'}
        if name == 'swift-http-server':
            state = {'revision': f'{i:040x}'}
        entries.append({'identity': name, 'kind': 'remoteSourceControl', 'location': f'https://github.com/example/{name}.git', 'state': state})
    return {'version': 3, 'pins': entries}


class ConsumerControls(unittest.TestCase):
    def test_seed_and_manifest(self):
        original = lock()
        before = copy.deepcopy(original)
        result = consumer.seed(original, original, 'a'*40)
        self.assertEqual(original, before)
        self.assertEqual(len(result['pins']), 30)
        self.assertEqual(consumer.pins(result)[consumer.HTTP]['state'], {'revision': 'a'*40})
        text = consumer.manifest('@DEPENDENCIES@', result)
        self.assertIn('revision: "' + 'a'*40 + '"', text)
        self.assertIn('branch: "main"', text)
        self.assertIn('traits: []', text)
        self.assertNotIn('.package(path:', text)

    def test_wrong_graph_rejected(self):
        original = lock()
        other = copy.deepcopy(original)
        other['pins'][0]['state']['revision'] = 'b'*40
        with self.assertRaisesRegex(ValueError, 'root/fixture pin mismatch'):
            consumer.seed(original, other, 'a'*40)

    def test_duplicate_rejected(self):
        original = lock()
        original['pins'].append(original['pins'][0])
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            consumer.pins(original)

    def test_revision_must_be_immutable(self):
        with self.assertRaisesRegex(ValueError, 'immutable HTTP'):
            consumer.seed(lock(), lock(), 'main')

    def test_graph_receipt(self):
        expected = consumer.seed(lock(), lock(), 'a'*40)
        heads = {n: p['state']['revision'] for n, p in consumer.pins(expected).items()}
        consumer.verify_graph(expected, dict(expected, originHash='optional'), heads)
        heads[consumer.HTTP] = 'b'*40
        with self.assertRaisesRegex(ValueError, 'checkout revision drift'):
            consumer.verify_graph(expected, expected, heads)

    def test_lock_drift_rejected(self):
        expected = consumer.seed(lock(), lock(), 'a'*40)
        actual = copy.deepcopy(expected)
        actual['pins'].pop()
        with self.assertRaisesRegex(ValueError, 'lock drift'):
            consumer.verify_graph(expected, actual, {})

    def test_runtime_markers(self):
        text = ''.join(f'H5_CONSUMER case={name} PASS\n' for name in consumer.CASES) + 'H5_CONSUMER mode=json COMPLETE\n'
        consumer.verify_output(text, 'json')
        for bad in (text.replace('case=joined PASS\n', ''), text + text, text.replace('mode=json', 'mode=sse'), text+'H5_CONSUMER_FAILED\n'):
            with self.subTest(bad=bad[-50:]), self.assertRaisesRegex(ValueError, 'runtime receipt'):
                consumer.verify_output(bad, 'json')

    def test_tls_issuer_pkce_and_replay(self):
        with tempfile.TemporaryDirectory() as tmp:
            ca, cert, key = consumer.certificates(Path(tmp))
            issuer = consumer.Issuer('https://127.0.0.1:12345/mcp', cert, key)
            worker = threading.Thread(target=issuer.serve_forever)
            worker.start()
            context = ssl.create_default_context(cafile=str(ca))
            def request(method, path, body=None):
                conn = http.client.HTTPSConnection('127.0.0.1', issuer.server_port, context=context, timeout=5)
                try:
                    headers = {'Content-Type': 'application/x-www-form-urlencoded'} if body else {}
                    conn.request(method, path, body=body, headers=headers)
                    response = conn.getresponse()
                    return response.status, response.getheader('Location'), response.read()
                finally:
                    conn.close()
            try:
                status, _, body = request('GET', '/.well-known/oauth-authorization-server')
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)['issuer'], issuer.url)
                verifier = 'v'*43
                challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
                params = dict(response_type='code', client_id=consumer.CLIENT, redirect_uri=consumer.REDIRECT,
                    code_challenge_method='S256', resource=issuer.resource, scope='read', state='s'*43, code_challenge=challenge)
                status, location, _ = request('GET', '/authorize?' + urlencode(params))
                self.assertEqual(status, 302)
                fields = parse_qs(urlsplit(location).query)
                self.assertEqual(fields['state'], ['s'*43])
                self.assertEqual(fields['iss'], [issuer.url])
                grant = dict(grant_type='authorization_code', code=fields['code'][0], redirect_uri=consumer.REDIRECT,
                    resource=issuer.resource, client_id=consumer.CLIENT, code_verifier='x'*43)
                self.assertEqual(request('POST', '/token', urlencode(grant))[0], 400)
                grant['code_verifier'] = verifier
                status, _, body = request('POST', '/token', urlencode(grant))
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)['access_token'], issuer.token)
                self.assertEqual(request('POST', '/token', urlencode(grant))[0], 400)
                self.assertEqual(issuer.counts, dict(metadata=1, authorize=1, token=1, rejected=2))
            finally:
                issuer.shutdown()
                worker.join(timeout=10)
                issuer.server_close()
                self.assertFalse(worker.is_alive())


if __name__ == '__main__':
    unittest.main()
