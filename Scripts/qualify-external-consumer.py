#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Build and run a remote-revision SwiftPM consumer on native macOS ARM64."""
import argparse
import base64
import copy
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
from urllib.parse import parse_qs, urlencode, urlsplit

HTTP = 'swift-mcp-server-http'
HTTP_URL = 'https://github.com/ThorFuchs/Swift-MCP-Server-HTTP.git'
DIRECT = (HTTP, 'swift-mcp-server', 'swift-json', 'swift-http-server', 'async-http-client', 'swift-nio-ssl')
CASES = ('tls_metadata', 'denials', 'oauth_login', 'tools_mirrors_progress', 'resources', 'prompts', 'restore_signout', 'joined')
REDIRECT = 'http://127.0.0.1:9/callback'
CLIENT = 'external-consumer'


def need(ok, message):
    if not ok:
        raise ValueError(message)


def pins(document):
    need(document.get('version') == 3, 'unsupported lock format')
    result = {}
    for p in document['pins']:
        name = p['identity'].lower()
        need(name == p['identity'] and name not in result, 'duplicate or noncanonical pin')
        need(p['kind'] == 'remoteSourceControl' and re.fullmatch(r'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', p['location']), 'unexpected pin source')
        need(re.fullmatch('[0-9a-f]{40}', p['state']['revision']), 'invalid pin revision')
        result[name] = p
    return result


def seed(root_lock, fixture_lock, sha):
    need(re.fullmatch('[0-9a-f]{40}', sha), 'expected immutable HTTP revision')
    expected = pins(root_lock)
    need(expected == pins(fixture_lock), 'root/fixture pin mismatch')
    need(len(expected) == 29 and HTTP not in expected, 'unexpected baseline graph size or HTTP pin')
    expected = copy.deepcopy(expected)
    expected[HTTP] = {'identity': HTTP, 'kind': 'remoteSourceControl', 'location': HTTP_URL, 'state': {'revision': sha}}
    need(all(name in expected for name in DIRECT), 'missing direct dependency')
    return {'version': 3, 'pins': [expected[n] for n in sorted(expected)]}


def manifest(template, lock):
    entries = pins(lock)
    lines = []
    for name in DIRECT:
        p = entries[name]
        s = p['state']
        if 'version' in s:
            need(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', s['version']), 'invalid dependency version')
            requirement = 'exact: ' + json.dumps(s['version'])
        elif 'branch' in s:
            need(name == 'swift-mcp-server' and s['branch'] == 'main', 'unexpected mutable dependency')
            requirement = 'branch: "main"'
        else:
            requirement = 'revision: ' + json.dumps(s['revision'])
        traits = ', traits: []' if name == 'swift-http-server' else ''
        lines.append('        .package(url: ' + json.dumps(p['location']) + ', ' + requirement + traits + '),')
    need(template.count('@DEPENDENCIES@') == 1, 'unexpected manifest template')
    result = template.replace('@DEPENDENCIES@', '\n'.join(lines))
    need('.package(path:' not in result and '@DEPENDENCIES@' not in result, 'consumer is not remote')
    return result


def verify_graph(expected, actual, checkout_heads):
    want = pins(expected)
    need(pins(actual) == want, 'consumer lock drift')
    need(checkout_heads == {n: p['state']['revision'] for n, p in want.items()}, 'actual checkout revision drift')


def verify_output(text, mode):
    observed = re.findall(r'^H5_CONSUMER case=(\S+) PASS$', text, re.M)
    completed = re.findall(r'^H5_CONSUMER mode=(\S+) COMPLETE$', text, re.M)
    need(observed == list(CASES) and completed == [mode] and 'H5_CONSUMER_FAILED' not in text,
         'missing, duplicate or unexpected runtime receipt')


def capture(cwd, *args):
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=120).strip()


def command(cwd, evidence, label, *args, env=None, timeout=None):
    print('=== ' + label + ' ===', flush=True)
    with (evidence / (label + '.log')).open('w') as log:
        result = subprocess.run(args, cwd=cwd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    need(result.returncode == 0, label + ' failed; inspect log')


def certificates(directory):
    # Short-lived local test CA and leaf; never use real host certificates.
    conf = directory / 'ca.cnf'
    conf.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\nCN=H5 consumer test CA\n[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n')
    leaf = directory / 'leaf.cnf'
    leaf.write_text('[req]\nprompt=no\ndistinguished_name=dn\n[dn]\nCN=127.0.0.1\n[leaf]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n')
    def openssl(*args):
        subprocess.run(['openssl', *args], cwd=directory, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=30)
    openssl('req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '2', '-config', 'ca.cnf', '-keyout', 'ca.key', '-out', 'ca.pem')
    openssl('req', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-config', 'leaf.cnf', '-keyout', 'leaf.key', '-out', 'leaf.csr')
    openssl('x509', '-req', '-in', 'leaf.csr', '-CA', 'ca.pem', '-CAkey', 'ca.key', '-CAcreateserial', '-days', '2', '-sha256', '-extfile', 'leaf.cnf', '-extensions', 'leaf', '-out', 'leaf.pem')
    openssl('verify', '-CAfile', 'ca.pem', 'leaf.pem')
    return tuple(directory / n for n in ('ca.pem', 'leaf.pem', 'leaf.key'))


class Issuer(ThreadingHTTPServer):
    daemon_threads = False

    def __init__(self, resource, cert, key):
        super().__init__(('127.0.0.1', 0), Handler)
        self.resource = resource
        self.url = f'https://127.0.0.1:{self.server_port}'
        self.token = secrets.token_urlsafe(32)
        self.code = secrets.token_urlsafe(32)
        self.challenge = None
        self.counts = dict(metadata=0, authorize=0, token=0, rejected=0)
        self.guard = threading.Lock()
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.load_cert_chain(cert, key)

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(5)
        try:
            return self.context.wrap_socket(sock, server_side=True), address
        except OSError:
            sock.close()
            with self.guard:
                self.counts['rejected'] += 1
            raise

    def handle_error(self, request, client_address):
        # Avoid recording arbitrary request content or secrets in test logs.
        with self.guard:
            self.counts['rejected'] += 1


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, document=None, location=None):
        body = json.dumps(document).encode() if document is not None else b''
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        if location is not None:
            self.send_header('Location', location)
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def reject(self):
        self.server.counts['rejected'] += 1
        self.reply(400, {'error': 'invalid_request'})

    def do_GET(self):
        s = self.server
        with s.guard:
            url = urlsplit(self.path)
            if url.path == '/.well-known/oauth-authorization-server' and not url.query:
                s.counts['metadata'] += 1
                self.reply(200, {'issuer': s.url, 'authorization_endpoint': s.url + '/authorize',
                    'token_endpoint': s.url + '/token', 'code_challenge_methods_supported': ['S256'],
                    'token_endpoint_auth_methods_supported': ['none'], 'scopes_supported': ['read'],
                    'authorization_response_iss_parameter_supported': True})
                return
            if url.path != '/authorize' or self.headers.get('Authorization'):
                return self.reject()
            fields = parse_qs(url.query, keep_blank_values=True)
            expected = {'response_type': ['code'], 'client_id': [CLIENT], 'redirect_uri': [REDIRECT],
                        'code_challenge_method': ['S256'], 'resource': [s.resource], 'scope': ['read']}
            if (set(fields) != set(expected) | {'state', 'code_challenge'} or
                    any(fields.get(k) != v for k, v in expected.items()) or s.counts['authorize'] or
                    any(len(fields[k]) != 1 or not re.fullmatch(r'[A-Za-z0-9_-]{43}', fields[k][0]) for k in ('state', 'code_challenge'))):
                return self.reject()
            s.challenge = fields['code_challenge'][0]
            s.counts['authorize'] += 1
            self.reply(302, location=REDIRECT + '?' + urlencode({'code': s.code, 'state': fields['state'][0], 'iss': s.url}))

    def do_POST(self):
        s = self.server
        with s.guard:
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if (self.path != '/token' or not 0 < size <= 8192 or self.headers.get('Authorization') or
                        self.headers.get_content_type() != 'application/x-www-form-urlencoded'):
                    return self.reject()
                fields = parse_qs(self.rfile.read(size).decode(), keep_blank_values=True)
            except (ValueError, UnicodeError):
                return self.reject()
            expected = {'grant_type': ['authorization_code'], 'code': [s.code], 'redirect_uri': [REDIRECT],
                        'resource': [s.resource], 'client_id': [CLIENT]}
            verifier = fields.get('code_verifier', [])
            if (set(fields) != set(expected) | {'code_verifier'} or any(fields.get(k) != v for k, v in expected.items()) or
                    len(verifier) != 1 or not re.fullmatch(r'[A-Za-z0-9_-]{43}', verifier[0]) or not s.challenge or s.counts['token']):
                return self.reject()
            calculated = base64.urlsafe_b64encode(hashlib.sha256(verifier[0].encode()).digest()).rstrip(b'=').decode()
            if not secrets.compare_digest(calculated, s.challenge):
                return self.reject()
            s.counts['token'] += 1
            self.reply(200, {'access_token': s.token, 'token_type': 'Bearer', 'scope': 'read', 'expires_in': 600})


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def runtime(binary, package, evidence, configuration, mode, certs):
    ca, cert, key = certs
    port = free_port()  # bind race is a failure, never silently retried
    issuer = Issuer(f'https://127.0.0.1:{port}/mcp', cert, key)
    worker = threading.Thread(target=issuer.serve_forever, daemon=True)
    worker.start()
    label = configuration + '-' + mode
    try:
        env = dict(os.environ, MCP_CONSUMER_SYNTHETIC_TOKEN=issuer.token)
        command(package, evidence, label, str(binary), mode, str(port), issuer.url, str(ca), str(cert), str(key), env=env, timeout=120)
        verify_output((evidence / (label + '.log')).read_text(), mode)
    finally:
        issuer.shutdown()
        worker.join(timeout=10)
        issuer.server_close()
        (evidence / (label + '-issuer.json')).write_text(json.dumps(issuer.counts, indent=2) + '\n')
    need(not worker.is_alive(), 'issuer thread did not join')
    need(issuer.counts == dict(metadata=1, authorize=1, token=1, rejected=0), 'unexpected issuer interaction counts')


def qualify(root, run_dir, sha, completed):
    need(capture(root, 'git', 'rev-parse', 'HEAD') == sha, 'unexpected source SHA')
    need(not capture(root, 'git', 'status', '--porcelain'), 'use a clean checkout')
    need(capture(root, 'uname', '-sm') == 'Darwin arm64', 'native macOS ARM64 required')
    need(int(capture(root, 'sw_vers', '-productVersion').split('.')[0]) >= 27, 'macOS 27+ required')
    swift = capture(root, 'swift', '--version')
    need(re.search(r'Swift version 6\.4\.2(?:\s|$)', swift), 'Swift 6.4.2 required')
    need(shutil.disk_usage(run_dir).free >= 25 * 1024**3, 'need at least 25 GiB free on consumer workspace volume')
    os.environ['SDKROOT'] = capture(root, 'xcrun', '--sdk', 'macosx', '--show-sdk-path')
    os.environ['GIT_TERMINAL_PROMPT'] = '0'
    evidence, package = run_dir / 'evidence', run_dir / 'package'
    source = root / 'Tools/ExternalConsumer'
    shutil.copytree(source / 'Sources', package / 'Sources')
    expected = seed(json.loads((root / 'Package.resolved').read_text()), json.loads((root / 'Tools/Conformance/SwiftFixture/Package.resolved').read_text()), sha)
    (package / 'Package.swift').write_text(manifest((source / 'Package.swift.in').read_text(), expected))
    (package / 'Package.resolved').write_text(json.dumps(expected, indent=2) + '\n')
    shutil.copyfile(package / 'Package.swift', evidence / 'Package.swift')
    shutil.copyfile(package / 'Package.resolved', evidence / 'expected.Package.resolved')
    (evidence / 'provenance.json').write_text(json.dumps({'source': sha, 'swift': swift,
        'os': capture(root, 'sw_vers'), 'xcode': capture(root, 'xcodebuild', '-version'),
        'backend': 'swiftbuild', 'pins': len(expected['pins'])}, indent=2) + '\n')

    def integrity(label):
        actual = json.loads((package / 'Package.resolved').read_text())
        dirs = list((package / '.build/checkouts').iterdir())
        heads = {}
        for n in pins(expected):
            matches = [p for p in dirs if p.name.lower() == n]
            need(len(matches) == 1, 'missing/ambiguous checkout: ' + n)
            heads[n] = capture(matches[0], 'git', 'rev-parse', '--verify', 'HEAD')
            need(not capture(matches[0], 'git', 'status', '--porcelain'), 'dirty checkout: ' + n)
        verify_graph(expected, actual, heads)
        (evidence / ('graph-' + label + '.json')).write_text(json.dumps({'lock': actual, 'checkout_heads': heads}, indent=2) + '\n')

    command(package, evidence, 'resolve', 'swift', 'package', '--force-resolved-versions', 'resolve')
    integrity('resolve')
    with tempfile.TemporaryDirectory(prefix='consumer-tls-', dir=run_dir) as temp:
        certs = certificates(Path(temp))
        for config in ('debug', 'release'):
            args = ('swift', 'build', '--build-system', 'swiftbuild', '--force-resolved-versions', '-c', config, '-j', '2')
            command(package, evidence, 'build-' + config, *args, '--product', 'HTTPExternalConsumer')
            integrity(config)
            binary = Path(capture(package, *args, '--show-bin-path')) / 'HTTPExternalConsumer'
            need(binary.is_file() and os.access(binary, os.X_OK), 'missing executable')
            for mode in ('json', 'sse'):
                runtime(binary, package, evidence, config, mode, certs)
                completed.append(config + '-' + mode)
                integrity(completed[-1])
    need(not capture(root, 'git', 'status', '--porcelain') and capture(root, 'git', 'rev-parse', 'HEAD') == sha, 'source drift')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('expected_sha')
    parser.add_argument('output_parent', type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    parent = args.output_parent.expanduser().resolve()
    need(parent != root and root not in parent.parents, 'external workspace must be outside SDK checkout')
    parent.mkdir(parents=True, exist_ok=True)
    run_dir = Path(tempfile.mkdtemp(prefix='http-consumer-', dir=parent))
    evidence = run_dir / 'evidence'
    evidence.mkdir()
    completed, result = [], 'FAILED'
    try:
        qualify(root, run_dir, args.expected_sha, completed)
        need(len(completed) == 4, 'incomplete runtime matrix')
        result = 'CONSUMER_PASS'
    except (Exception, KeyboardInterrupt) as error:
        # Expected errors have fixed messages or paths, not request bodies.
        print(f'Consumer qualification failed: {type(error).__name__}: {error}', file=sys.stderr)
        (evidence / 'failure.txt').write_text(f'{type(error).__name__}: {error}\n')
    finally:
        (evidence / 'decision.json').write_text(json.dumps({'outcome': result, 'completed': completed}, indent=2) + '\n')
        archive_path = Path(str(run_dir) + '.tar.gz')
        with tarfile.open(archive_path, 'w:gz') as archive:
            archive.add(evidence, arcname='evidence')
        print(f'ARCHIVE: {archive_path} ({result})', flush=True)
        print(f'Consumer worktree retained: {run_dir / "package"}', flush=True)
    return 0 if result == 'CONSUMER_PASS' else 1


if __name__ == '__main__':
    sys.exit(main())
