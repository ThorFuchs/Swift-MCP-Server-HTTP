#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""A2.1: reproduce B2/B3 against only the new Core revision; diagnostic graph."""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tarfile
import tempfile

HTTP = 'c99b65a9ee7879187e6d67e9771b8daa30115502'
CORE = '1237d9f11e580f9c68ba6d7064d0c16de7fa1cd3'
REFEREE = 'b56fb575e61edaac83c2008af40a6a78b47815c4038a02a9b04cd336d38832a0'
FIXTURE = 'Tools/Conformance/SwiftFixture'
INPUTS = ('Package.swift', 'Package.resolved', FIXTURE+'/Package.swift', FIXTURE+'/Package.resolved',
          'Tools/Conformance/package.json', 'Tools/Conformance/package-lock.json',
          'Tools/Conformance/.nvmrc', 'Tools/Conformance/.npmrc')
FILTER = ('HTTPClientTransportCases|AuthorizationRetry|OAuthClientCodeFlow|OAuthClientDiscoveryAndIdentity|'
          'OAuthClientScopesAndRefresh|OAuthClientLifecycle|WWWAuthenticateParsing|'
          'nativeHTTPPeerDisconnectCancelsWithoutProviderCompletion|nativeHTTPRepeatedFINReleasesOwnersAndRecovers|'
          'nativeTLSPeerProcessExitCancelsBeforeResponseHead')
PROMPT = 'sep-2575-server-sends-prompts-list-changed-on-subscription'
WARNING = ('Mutated the prompt list but no notifications/prompts/list_changed arrived on the open '
           'subscription stream. This is a SHOULD requirement.')


def need(ok, message):
    if not ok:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as f:
        for block in iter(lambda: f.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def put(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n')


def capture(args, cwd):
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=60).strip()


def audit_records(records, mode, role):
    expected = 53 if role == 'server' else 37
    need(len(records) == expected and len({name for name, _ in records}) == expected, 'scenario inventory differs')
    totals = Counter()
    warnings, skips = [], []
    for name, checks in records:
        need(isinstance(checks, list) and bool(checks), 'empty checks: '+name)
        for check in checks:
            status = check['status']
            need(status in ('SUCCESS', 'WARNING', 'SKIPPED', 'INFO'), 'unexpected status: '+str(status))
            totals[status] += 1
            if status == 'WARNING':
                need(role == 'server' and mode == 'debug' and name == 'server-stateless' and
                     check['id'] == PROMPT and check.get('errorMessage') == WARNING and
                     not (check.get('details') or {}).get('untestable'), 'unexpected warning: '+name)
                warnings.append({'scenario': name, 'check': check})
            if status == 'SKIPPED':
                skips.append({'scenario': name, 'check': check})
    need(len(warnings) <= 1, 'duplicate warning')
    if role == 'server':
        need(len(skips) == 1 and skips[0]['scenario'] == 'tasks-status-notifications', 'server skip inventory')
        need(totals['SUCCESS'] == 242-len(warnings), 'server success inventory')
    else:
        need(len(skips) == 2 and all(s['scenario'] == 'http-standard-headers' for s in skips), 'client skip inventory')
        expected_messages = {f'Client did not send a {method} request; Mcp-Method header was not exercised for this method.'
                             for method in ('initialize', 'notifications/initialized')}
        need({s['check'].get('errorMessage') for s in skips} == expected_messages, 'client skip reasons')
        need(totals['SUCCESS'] == 399, 'client success inventory')
    return {'scenarios': expected, 'counts': dict(totals), 'warnings': warnings, 'skips': skips}


def audit_leg(leg, mode, role, checkout):
    records = []
    for p in sorted(leg.rglob('checks.json')):
        if role == 'server':
            m = re.fullmatch(r'server-(.+)-\d{4}-\d{2}-\d{2}T[\d-]+Z', p.parent.name)
            need(m is not None, 'unexpected result directory: '+p.parent.name)
            name = m[1]
        else:
            name = p.relative_to(leg).parts[0]
        records.append((name, json.loads(p.read_text())))
    result = audit_records(records, mode, role)
    ledger = (leg/'referee-exits.tsv').read_text().splitlines()
    need(ledger[0] == 'scenario\treferee_exit' and len(ledger) == (5 if role == 'server' else 38)
         and all(line.endswith('\t0') for line in ledger[1:]), 'nonzero or incomplete referee exits')
    reported, binary = (leg/'fixture.sha256').read_text().strip().split(None, 1)
    path = Path(binary).resolve()
    need(checkout in path.parents and path.name == ('SwiftConformanceServer' if role == 'server' else 'SwiftConformanceClient')
         and digest(path) == reported, 'fixture digest mismatch')
    need(digest(checkout/'Tools/Conformance/node_modules/@modelcontextprotocol/conformance/dist/index.js') == REFEREE,
         'published referee bundle differs')
    if role == 'server':
        log = (leg/'fixture.stderr').read_text(errors='replace')
        need('FIXTURE_STOPPED started=2 joined=2 active=0' in log, 'missing server fixture join receipt')
    put(leg/'a21-raw-audit.json', result)
    return result


def qualify(root, runner, checkout, out):
    rows = []
    def run(label, args, cwd=checkout, timeout=2400):
        print(label+' ...', flush=True)
        with (out/(label+'.log')).open('wb') as f:
            proc = subprocess.Popen(args, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                rc = proc.wait(timeout=timeout)
            except BaseException:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=10)
                raise
        rows.append({'step': label, 'exit': rc, 'argv': list(map(str, args))})
        put(out/'steps.json', rows)
        print(label+': exit '+str(rc), flush=True)
        need(rc == 0, 'failed step: '+label)
    os.environ.update(LC_ALL='C', MCP_STRICT_RESOLUTION='1', SWIFT_BUILD_JOBS='2')
    arch = capture(['uname','-sm'], root)
    swift = capture(['swift','--version'], root)
    os_version = capture(['sw_vers','-productVersion'], root)
    node, npm = capture(['node','--version'], root), capture(['npm','--version'], root)
    put(out/'provenance.json', {'runner': runner, 'http': HTTP, 'core': CORE, 'arch': arch, 'swift': swift,
                               'os': os_version, 'node': node, 'npm': npm})
    need(arch == 'Darwin arm64' and int(os_version.split('.')[0]) >= 27 and
         re.search(r'Swift version 6\.4\.2(?:\s|$)', swift) and node == 'v24.22.3' and npm == '11.19.1', 'toolchain differs')
    os.environ['SDKROOT'] = capture(['xcrun','--sdk','macosx','--show-sdk-path'], root)
    run('clone', ['git','clone','--no-hardlinks','--no-checkout',str(root),str(checkout)], root, 180)
    run('checkout', ['git','checkout','--detach',HTTP], timeout=60)
    need(capture(['git','rev-parse','HEAD'],checkout) == HTTP and not capture(['git','status','--porcelain'],checkout), 'wrong/dirty fixture')
    checker = root/'Scripts/check-core-a16n-notifications.py'
    run('seed', [sys.executable,'-I',str(checker),'seed',CORE,str(out)], timeout=60)
    run('resolve-root', ['swift','package','resolve'])
    run('resolve-fixture', ['swift','package','--package-path',FIXTURE,'resolve'])
    before = {p:digest(checkout/p) for p in INPUTS}
    put(out/'inputs-before.json', before)
    def integrity(label):
        run('verify-'+label, [sys.executable,'-I',str(checker),'verify',str(out)], timeout=120)
        now = {p:digest(checkout/p) for p in INPUTS}
        put(out/('inputs-'+label+'.json'), now)
        need(now == before, 'dependency byte drift: '+label)
        status = capture(['git','status','--porcelain'],checkout)
        (out/('status-'+label+'.txt')).write_text(status+'\n')
        need(set(x[3:] for x in status.splitlines()) == set(INPUTS[:4]), 'unexpected tracked/untracked changes')
    integrity('resolved')
    for label, path in [('root',INPUTS[1]),('fixture',INPUTS[3]),('npm',INPUTS[5])]:
        (out/(label+'.before.json')).write_bytes((checkout/path).read_bytes())
    receipts = []
    for mode in ('debug','release'):
        label = mode+'-consumer'
        run(label,['swift','test','--force-resolved-versions','-c',mode,'--jobs','2','--filter',FILTER])
        run(label+'-receipt',[sys.executable,'-I','Scripts/check-core-a16e-consumer-receipts.py',str(out/(label+'.log'))],timeout=60)
        integrity(label)
        os.environ['MCP_HTTP_FIXTURE_CONFIGURATION'] = mode
        for role, script in [('server','conformance.sh'),('client','client-conformance.sh')]:
            label = mode+'-'+role
            leg = out/label
            leg.mkdir()
            run(label,['bash','Scripts/'+script,str(leg)])
            run(label+'-receipt',[sys.executable,'-I','Scripts/check-core-a16e-referee-receipts.py',role,str(leg),str(out/(label+'.log'))],timeout=60)
            receipt = audit_leg(leg,mode,role,checkout)
            receipts.append({'leg':label, **receipt})
            put(out/'referee-receipts.json',receipts)
            integrity(label)
    for label,path in [('root',INPUTS[1]),('fixture',INPUTS[3]),('npm',INPUTS[5])]:
        (out/(label+'.after.json')).write_bytes((checkout/path).read_bytes())
    put(out/'decision.json',{'outcome':'PASS_SCOPED_A21_HTTP_INTEROP','release_gate':'NOT_EVALUATED',
                            'consumer_functions_per_mode':43,'consumer_cases_per_mode':98,'referee_legs':receipts})


def main():
    root = Path(__file__).resolve().parents[1]
    need(len(sys.argv) == 3, 'usage: qualify-core-a21-http.py RUNNER_SHA EVIDENCE_DIR')
    runner = sys.argv[1]
    need(re.fullmatch('[0-9a-f]{40}',runner) and capture(['git','rev-parse','HEAD'],root)==runner
         and not capture(['git','status','--porcelain'],root),'wrong or dirty runner')
    dest = Path(sys.argv[2]).expanduser().resolve()
    need(dest != root and root not in dest.parents,'evidence must be outside runner checkout')
    dest.mkdir(parents=True,exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='core-a21-http-',dir=dest))
    work = Path(tempfile.mkdtemp(prefix='core-a21-work-',dir=dest))
    rc = 1
    try:
        qualify(root,runner,work/'http',out)
        rc = 0
    except Exception as exc:
        (out/'error.txt').write_text(str(exc)+'\n')
        print('FAIL:',exc,file=sys.stderr)
    finally:
        put(out/'summary.json',{'exit_code':rc,'work':str(work)})
        with tarfile.open(str(out)+'.tar.gz','w:gz') as tar:
            tar.add(out,arcname='.')
        print(f'ARCHIVE: {out}.tar.gz (exit {rc})',flush=True)
    return rc


if __name__ == '__main__':
    sys.exit(main())
