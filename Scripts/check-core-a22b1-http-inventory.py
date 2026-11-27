#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Exact frozen scenario sets layered on the unchanged B3 raw receipt gate."""
import hashlib
import json
from pathlib import Path
import re
import sys
import unittest

FROZEN = 'b0c4f8560429e8f4b6c89833cc0b35405bc004ff'
CORE = '5f6892cf9d3f81e1122612e9d3f3066ad0f03a3c'
TASKS = set('''tasks-lifecycle tasks-capability-negotiation tasks-wire-fields
 tasks-request-state-removal tasks-mrtr-input tasks-request-headers
 tasks-dispatch-and-envelope tasks-status-notifications tasks-required-task-error
 tasks-mrtr-composition'''.split())
SKILLS = set('sep-2640-skills-enumeration sep-2640-skills-manifest sep-2640-skills-directory'.split())
PENDING = set('json-schema-2020-12 http-header-validation http-custom-header-server-validation'.split())
SUPPLEMENTS = set('''json-schema-2020-12-preservation sep-2640-client-no-prefetch
 sep-2640-client-verify-digest sep-2640-client-verify-size sep-2640-client-verify-frontmatter'''.split())
TASK_SKIP = ('Skipped: SEP-2663 delivers notifications/tasks via the SEP-2575 subscriptions/listen stream, '
             'not via the tools/call POST SSE response that the prior harness observed. '
             'The harness needs a rewrite against the new channel; tracked as a follow-up.')
CLIENT_SKIPS = {('sep-2243-client-includes-standard-headers',
                f'Client did not send a {m} request; Mcp-Method header was not exercised for this method.')
                for m in ('initialize', 'notifications/initialized')}


def need(ok, message):
    if not ok:
        raise ValueError(message)


def required_sets(raw):
    blob = hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
    need(blob == FROZEN, 'frozen requirements blob differs')
    sections = {'server': [], 'client': []}
    section = None
    for line in raw.decode('utf-8').splitlines():
        if line in ('server:', 'client:'):
            section = line[:-1]
        elif line == 'not_scored:':
            section = None
        elif section and line.strip() and not line.lstrip().startswith('#'):
            match = re.fullmatch(r'  - ([A-Za-z0-9_/-]+)', line)
            need(match is not None, 'unexpected required-list syntax')
            sections[section].append(match[1])
    need(len(sections['server']) == len(set(sections['server'])) == 37 and
         len(sections['client']) == len(set(sections['client'])) == 32, 'frozen required inventory differs')
    return {role: set(names) for role, names in sections.items()}


def plan(required, role):
    if role == 'server':
        groups = {'required': required[role], 'tasks': TASKS, 'skills': SKILLS, 'pending_diagnostics': PENDING}
    else:
        groups = {'required': required[role], 'supplements': SUPPLEMENTS}
    names = [name.replace('/', '-') if role == 'client' else name for group in groups.values() for name in group]
    need(len(names) == len(set(names)) == (53 if role == 'server' else 37), 'plan collision or missing names')
    return groups, set(names)


def audit(required, role, records):
    groups, names = plan(required, role)
    need(len(records) == len(names) and {n for n, _ in records} == names, 'exact scenario set differs')
    for name, checks in records:
        need(isinstance(checks, list) and checks, 'empty receipt '+name)
        need(all(isinstance(x, dict) and x.get('status') in ('SUCCESS','WARNING','SKIPPED','INFO') for x in checks),
             'invalid check status '+name)
        skips = [(x.get('id'), x.get('errorMessage')) for x in checks if x['status'] == 'SKIPPED']
        if role == 'server' and name == 'tasks-status-notifications':
            need(len(checks) == 1 and skips == [('tasks-status-notifications', TASK_SKIP)], 'unexpected Tasks skip')
        else:
            need(any(x['status'] == 'SUCCESS' for x in checks), 'no executed successful check '+name)
            if role == 'client' and name == 'http-standard-headers':
                need(len(skips) == 2 and set(skips) == CLIENT_SKIPS, 'unexpected header skips')
            else:
                need(not skips, 'unexpected skip '+name)
    return {k: sorted(v) for k, v in groups.items()}


def collect(leg, role):
    rows = []
    for p in sorted(leg.rglob('checks.json')):
        if role == 'server':
            m = re.fullmatch(r'server-(.+)-\d{4}-\d{2}-\d{2}T[\d-]+Z', p.parent.name)
            need(m is not None, 'unexpected server receipt directory')
            name = m[1]
        else:
            name = p.relative_to(leg).parts[0]
        rows.append((name,json.loads(p.read_text())))
    return rows


def verify(checkout, role, leg):
    import subprocess
    fixture = checkout/'Tools/Conformance/SwiftFixture/.build/checkouts'
    cores = [p for p in fixture.iterdir() if p.name.lower() == 'swift-mcp-server']
    need(len(cores) == 1, 'missing actual fixture Core checkout')
    sha = subprocess.check_output(['git','-C',str(cores[0]),'rev-parse','HEAD'],text=True,timeout=60).strip()
    need(sha == CORE, 'wrong actual fixture Core revision')
    raw = (cores[0]/'Reference/Conformance/requirements/2026-07-28.yaml').read_bytes()
    required = required_sets(raw)
    groups = audit(required,role,collect(leg,role))
    (leg/'a22a-exact-inventory.json').write_text(json.dumps({'frozen_blob':FROZEN,'core':sha,'groups':groups},indent=2,sort_keys=True)+'\n')
    print('PASS: exact frozen required sets and supplemental scenario names; historical skip identities unchanged')


class Controls(unittest.TestCase):
    def setUp(self):
        self.required = {'server':{f'server-{i}' for i in range(37)}, 'client':{f'client-{i}' for i in range(32)}}
    def rows(self,role):
        _,names = plan(self.required,role)
        rows = [(n,[{'status':'SUCCESS'}]) for n in sorted(names)]
        if role == 'server':
            rows = [(n,[{'id':n,'status':'SKIPPED','errorMessage':TASK_SKIP}] if n == 'tasks-status-notifications' else c) for n,c in rows]
        return rows
    def test_exact_server(self):
        self.assertEqual(len(audit(self.required,'server',self.rows('server'))['required']),37)
    def test_same_count_wrong_name(self):
        rows=self.rows('server'); rows[0]=('invented',rows[0][1])
        with self.assertRaises(ValueError): audit(self.required,'server',rows)
    def test_duplicate(self):
        rows=self.rows('server'); rows[0]=rows[1]
        with self.assertRaises(ValueError): audit(self.required,'server',rows)
    def test_unexecuted_required(self):
        rows=self.rows('server'); i=next(i for i,(n,_) in enumerate(rows) if n in self.required['server']); rows[i]=(rows[i][0],[{'status':'INFO'}])
        with self.assertRaises(ValueError): audit(self.required,'server',rows)
    def test_wrong_tasks_skip(self):
        rows=self.rows('server'); next(c for n,c in rows if n=='tasks-status-notifications')[0]['errorMessage']='other'
        with self.assertRaises(ValueError): audit(self.required,'server',rows)
    def test_client_supplement_not_required(self):
        groups=audit(self.required,'client',self.rows('client')); self.assertEqual((len(groups['required']),len(groups['supplements'])),(32,5))
    def test_frozen_blob_mismatch(self):
        with self.assertRaises(ValueError): required_sets(b'server:\n')


if __name__ == '__main__':
    if sys.argv[1:] == ['--selftest']:
        unittest.main(argv=[sys.argv[0]],verbosity=2)
    else:
        need(len(sys.argv)==4 and sys.argv[2] in ('server','client'),'usage: checker CHECKOUT server|client LEG')
        verify(Path(sys.argv[1]),sys.argv[2],Path(sys.argv[3]))
