#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Gate HTTP client qualification against the immutable Core requirements.

The reference YAML is not copied or edited. This reader accepts only the exact
frozen file and its narrow scalar-list/record structure, not arbitrary YAML.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

REFERENCE = Path('Reference/Conformance/requirements/2026-07-28.yaml')
REFERENCE_BLOB = 'b0c4f8560429e8f4b6c89833cc0b35405bc004ff'
CORE = 'swift-mcp-server'
SKILLS = (
    'sep-2640-client-no-prefetch', 'sep-2640-client-verify-digest',
    'sep-2640-client-verify-size', 'sep-2640-client-verify-frontmatter',
)
SCHEMA = 'json-schema-2020-12-preservation'
A6 = {
    'auth/client-credentials-jwt', 'auth/client-credentials-basic',
    'auth/enterprise-managed-authorization', 'auth/dpop', 'auth/dpop-nonce',
    'auth/wif-jwt-bearer',
}
STATUSES = ('SUCCESS', 'FAILURE', 'WARNING', 'SKIPPED', 'INFO')
NAME = r'[a-zA-Z0-9_/-]+'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def blob_id(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


def parse_reference(data):
    require(blob_id(data) == REFERENCE_BLOB, 'frozen requirements blob mismatch')
    text = data.decode('utf-8')
    def section(name, following):
        match = re.search(r'^' + name + r':\n([\s\S]*?)(?=^' + following + r':)', text, re.M)
        require(match is not None, 'missing requirements section: ' + name)
        items = [line for line in match[1].splitlines() if line.strip() and not line.lstrip().startswith('#')]
        require(all(re.fullmatch(r'  - ' + NAME, line) for line in items), 'unexpected required-list syntax')
        names = [line[4:] for line in items]
        require(names and len(names) == len(set(names)), 'empty/duplicate required scenario')
        return names
    required = section('client', 'not_scored')
    server = section('server', 'client')
    not_scored = text.split('\nnot_scored:\n', 1)[1]
    records = re.findall(r'^  - scenario: (' + NAME + r')\n    leg: (client|server)\n    reason: ([a-z-]+)$', not_scored, re.M)
    client_records = [(name, reason) for name, leg, reason in records if leg == 'client']
    optional = dict(client_records)
    require(len(optional) == len(client_records), 'duplicate optional client scenario')
    require(optional.get(SCHEMA) == 'added-after-release', 'schema classification changed')
    require({name for name, reason in client_records if reason == 'extension'} == A6,
            'A6 extension classification changed')
    require(set(optional) == A6 | {SCHEMA}, 'unclassified optional client scenarios')
    extras = (SCHEMA, *SKILLS)
    require(not set(required) & (set(extras) | A6), 'required/extra overlap')
    require(len(required + list(extras)) == len(set(required + list(extras))), 'duplicate selected scenario')
    return {'required': required, 'server_required': server, 'additional': [SCHEMA],
            'extensions': list(SKILLS), 'unsupported_a6': sorted(A6)}


def core_revision(lock):
    data = json.loads(lock.read_text())
    require(data.get('version') == 3, f'unsupported lock format: {lock}')
    pins = [p for p in data['pins'] if p['identity'].lower() == CORE]
    require(len(pins) == 1, f'missing/ambiguous Core pin: {lock}')
    revision = pins[0]['state']['revision']
    require(isinstance(revision, str) and re.fullmatch('[0-9a-f]{40}', revision), 'invalid Core revision')
    return revision


def load_plan(root):
    fixture = root / 'Tools/Conformance/SwiftFixture'
    revision = core_revision(root / 'Package.resolved')
    require(core_revision(fixture / 'Package.resolved') == revision, 'root/fixture Core revision mismatch')
    matches = [p for p in (fixture / '.build/checkouts').iterdir() if p.name.lower() == CORE]
    require(len(matches) == 1, 'missing/ambiguous fixture Core checkout')
    checkout = matches[0]
    actual = subprocess.check_output(['git', '-C', str(checkout), 'rev-parse', '--verify', 'HEAD'], text=True).strip()
    require(actual == revision, 'actual Core checkout differs from lock')
    plan = parse_reference((checkout / REFERENCE).read_bytes())
    return dict(plan, reference_blob=REFERENCE_BLOB, core_revision=revision, spec_version='2026-07-28')


def inspect_case(scenario, directory, log, exit_code):
    require(exit_code == 0, f'referee exit {exit_code}')
    text = log.read_text(errors='replace')
    require(f'Starting scenario: {scenario}' in text.splitlines(), 'missing scenario start')
    require('✅ OVERALL: PASSED' in text.splitlines(), 'missing successful referee disposition')
    receipts = list(directory.rglob('checks.json'))
    require(len(receipts) == 1, 'missing/ambiguous raw checks receipt')
    checks = json.loads(receipts[0].read_text())
    require(isinstance(checks, list) and checks, 'empty/malformed checks receipt')
    require(all(isinstance(c, dict) and c.get('status') in STATUSES for c in checks), 'unknown/malformed check status')
    counts = Counter(c['status'] for c in checks)
    require(counts['SUCCESS'] > 0 and not counts['FAILURE'] and not counts['WARNING'], 'non-passing raw checks')
    summaries = re.findall(r'^Passed: (\d+)/(\d+), (\d+) failed, (\d+) warnings$', text, re.M)
    require(len(summaries) == 1, 'missing/ambiguous summary')
    require(tuple(map(int, summaries[0])) == (counts['SUCCESS'], counts['SUCCESS'], 0, 0), 'summary/raw mismatch')
    return {status: counts[status] for status in STATUSES}


def run(root, referee, client, out):
    plan = load_plan(root)
    require(referee.is_file() and client.is_file(), 'missing referee/fixture executable')
    out.mkdir(parents=True, exist_ok=True)
    require(not any(out.iterdir()), 'use a fresh client conformance output directory')
    (out / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    cases = []
    for category in ('required', 'additional', 'extensions'):
        for scenario in plan[category]:
            slug = scenario.replace('/', '-')
            directory = out / slug
            log = out / (slug + '.log')
            args = [str(referee), 'client', '--command', str(client), '--scenario', scenario,
                    '--spec-version', plan['spec_version'], '--output-dir', str(directory)]
            if category == 'extensions':
                args.append('--force')
            with log.open('w') as stream:
                rc = subprocess.run(args, cwd=root, stdout=stream, stderr=subprocess.STDOUT).returncode
            result = {'scenario': scenario, 'category': category, 'exit': rc, 'pass': False}
            try:
                result['checks'] = inspect_case(scenario, directory, log, rc)
                result['pass'] = True
                n = result['checks']['SUCCESS']
                print(f'ok   {scenario}: Passed: {n}/{n}, 0 failed, 0 warnings', flush=True)
            except (OSError, ValueError) as error:
                result['reason'] = str(error)
                print(f'FAIL {scenario}: {error}', flush=True)
            cases.append(result)
    summary = {}
    for category in ('required', 'additional', 'extensions'):
        selected = [r for r in cases if r['category'] == category]
        summary[category] = {'passed': sum(r['pass'] for r in selected), 'expected': len(plan[category])}
        print(f"{category} client scenarios: {summary[category]['passed']}/{summary[category]['expected']} passed")
    print(f"unsupported A6 extensions (not scored): {len(plan['unsupported_a6'])}")
    (out / 'summary.json').write_text(json.dumps({'plan': plan, 'categories': summary, 'cases': cases}, indent=2) + '\n')
    require(load_plan(root) == plan, 'Core requirements/checkout drift during referee run')
    return 0 if all(r['pass'] for r in cases) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('referee', type=Path)
    parser.add_argument('client', type=Path)
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    try:
        return run(*(p.resolve() for p in (args.root, args.referee, args.client, args.out)))
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'Client coverage gate failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
