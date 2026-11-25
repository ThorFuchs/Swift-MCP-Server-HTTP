#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Run the pinned server referee and independently validate exact coverage."""
import argparse
from collections import Counter
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location('coverage', Path(__file__).with_name('client-conformance-gate.py'))
coverage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(coverage)
require = coverage.require
STATUSES = coverage.STATUSES
SKILLS = ('sep-2640-skills-enumeration', 'sep-2640-skills-manifest', 'sep-2640-skills-directory')
TASK_SKIP = 'tasks-status-notifications'
SKIP_REASON = ('Skipped: SEP-2663 delivers notifications/tasks via the SEP-2575 subscriptions/listen stream, '
               'not via the tools/call POST SSE response that the prior harness observed. The harness needs '
               'a rewrite against the new channel; tracked as a follow-up.')
DIR = re.compile(r'server-(.+)-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z')


def server_plan(shared):
    plan = {key: shared[key] for key in ('core_revision', 'reference_blob', 'spec_version')}
    plan.update(required=shared['server_required'], tasks=shared['server_tasks'],
                pending=shared['server_pending'], skills=list(SKILLS))
    names = plan['required'] + plan['tasks'] + plan['pending'] + plan['skills']
    require(len(names) == len(set(names)), 'duplicate/overlapping server scenario')
    require(plan['required'] and plan['pending'] and TASK_SKIP in plan['tasks'], 'incomplete server plan')
    require(all(n.startswith('tasks-') for n in plan['tasks']), 'unexpected frozen extension')
    return plan


def receipts(directory, expected):
    result = {}
    for path in sorted(directory.iterdir()):
        match = DIR.fullmatch(path.name)
        require(path.is_dir() and match is not None, f'unexpected result entry: {path.name}')
        name = match[1]
        require(name in expected and name not in result, f'unknown/duplicate scenario: {name}')
        checks = json.loads((path / 'checks.json').read_text())
        require(isinstance(checks, list) and checks, f'{name}: empty/malformed checks')
        require(all(isinstance(c, dict) and isinstance(c.get('id'), str) and c['id']
                    and c.get('status') in STATUSES for c in checks), f'{name}: invalid check')
        result[name] = checks
    require(set(result) == set(expected), f'missing scenarios: {sorted(set(expected) - set(result))}')
    return result


def counts(checks):
    c = Counter(check['status'] for check in checks)
    return {status: c[status] for status in STATUSES}


def unique_rows(rows, label):
    result = {}
    for name, *values in rows:
        require(name not in result, f'duplicate {label}: {name}')
        result[name] = tuple(values)
    return result


def suite_log(text, plan, raw):
    started = re.findall(r'^=== Running scenario: (\S+) ===$', text, re.M)
    require(len(started) == len(raw) and set(started) == set(raw), 'suite start-set mismatch')
    require(text.count('=== SUMMARY ===') == 1, 'missing/ambiguous suite summary')
    summary = text.split('=== SUMMARY ===', 1)[1]
    rows = re.findall(r'^[✓✗] (\S+): (\d+) passed, (\d+) failed$', summary, re.M)
    observed = unique_rows(rows, 'suite summary')
    expected = {n: tuple(str(counts(c)[s]) for s in ('SUCCESS', 'FAILURE')) for n, c in raw.items()}
    require(observed == expected, 'suite summary/raw mismatch')
    totals = re.findall(r'^Total: (\d+) passed, (\d+) failed$', summary, re.M)
    require(totals == [(str(sum(int(v[0]) for v in expected.values())),
                        str(sum(int(v[1]) for v in expected.values())))], 'suite totals mismatch')
    optional = re.findall(r'^  [✓✗] (\S+) \((extension|pending)\)$', summary, re.M)
    require(unique_rows(optional, 'not-scored scenario') ==
            {**{n: ('extension',) for n in plan['tasks']}, **{n: ('pending',) for n in plan['pending']}},
            'not-scored classification mismatch')
    headers = re.findall(r'^Not scored for (\S+): (\d+) scenario\(s\) run, (\d+) failing\. These do not affect conformance\.$', summary, re.M)
    expected_optional = plan['tasks'] + plan['pending']
    require(headers == [(plan['spec_version'], str(len(expected_optional)),
                         str(sum(counts(raw[n])['FAILURE'] > 0 for n in expected_optional)))], 'not-scored total mismatch')


def skill_log(text, name, check_counts):
    started = re.findall(r"^Running client scenario '([^']+)' against server:", text, re.M)
    require(started == [name], f'{name}: wrong/missing skill invocation')
    s, f, w = (check_counts[k] for k in ('SUCCESS', 'FAILURE', 'WARNING'))
    require(re.findall(r'^Passed: (\d+)/(\d+), (\d+) failed, (\d+) warnings$', text, re.M)
            == [(str(s), str(s + f), str(f), str(w))], f'{name}: skill summary/raw mismatch')


def classify(name, category, checks):
    c = counts(checks)
    if name == TASK_SKIP and c['SKIPPED']:
        require(category == 'tasks' and len(checks) == 1 and checks[0]['id'] == TASK_SKIP
                and checks[0].get('errorMessage') == SKIP_REASON, 'unexpected Tasks skip receipt')
        return 'KNOWN_UPSTREAM_SKIP'
    require(not c['SKIPPED'], f'{name}: unexpected skipped check')
    require(c['SUCCESS'] + c['FAILURE'] > 0, f'{name}: no executed checks')
    if category == 'pending':
        return 'DIAGNOSTIC_FAILURE' if c['FAILURE'] else 'DIAGNOSTIC_PASS'
    require(not c['FAILURE'] and c['SUCCESS'] > 0, f'{name}: failed executed checks')
    return 'PASS_WITH_WARNING' if c['WARNING'] else 'PASS'


def evaluate(plan, raw, skills, stdout, skill_logs, suite_exit, skill_exits):
    suite_names = plan['required'] + plan['tasks'] + plan['pending']
    require(set(raw) == set(suite_names) and set(skills) == set(plan['skills']), 'raw scenario-set mismatch')
    require(set(skill_exits) == set(skill_logs) == set(plan['skills']), 'skill process-set mismatch')
    require(suite_exit == 0, f'requirements referee exit {suite_exit}')
    suite_log(stdout, plan, raw)
    cases = []
    for category in ('required', 'tasks', 'pending', 'skills'):
        for name in plan[category]:
            checks = (skills if category == 'skills' else raw)[name]
            c = counts(checks)
            if category == 'skills':
                require(skill_exits[name] == 0, f'{name}: referee exit {skill_exits[name]}')
                skill_log(skill_logs[name], name, c)
            status = classify(name, category, checks)
            cases.append({'scenario': name, 'category': category, 'outcome': status, 'checks': c,
                          'warnings': [check['id'] for check in checks if check['status'] == 'WARNING']})
    return cases


def report(cases):
    for category in ('required', 'tasks', 'skills', 'pending'):
        items = [case for case in cases if case['category'] == category]
        passed = sum(case['outcome'] in ('PASS', 'PASS_WITH_WARNING', 'DIAGNOSTIC_PASS') for case in items)
        skips = sum(case['outcome'] == 'KNOWN_UPSTREAM_SKIP' for case in items)
        print(f'{category} server scenarios: {passed}/{len(items)} passed; {skips} known upstream skip(s)')
    for case in cases:
        if case['outcome'] not in ('PASS', 'DIAGNOSTIC_PASS') or case['warnings']:
            print(f"{case['outcome']} {case['scenario']} warnings={case['warnings']}")
    print('server coverage gate passed (known upstream skip is not a pass)')


def invoke(referee, args, stdout, stderr):
    with stdout.open('w') as out, stderr.open('w') as err:
        return subprocess.run([str(referee), 'server', *args], stdout=out, stderr=err).returncode


def run(root, referee, url, out):
    plan = server_plan(coverage.load_plan(root))
    require(referee.is_file(), 'missing referee executable')
    require({p.name for p in out.iterdir()} <= {'fixture.stderr'}, 'use a fresh server evidence directory')
    (out / 'plan.json').write_text(json.dumps(plan, indent=2) + '\n')
    common = ['--url', url, '--timeout', '90000']
    suite_exit = invoke(referee, [*common, '--requirements', plan['spec_version'], '--output-dir', str(out / 'results')],
                        out / 'referee.stdout', out / 'referee.stderr')
    exits = {}
    logs = {}
    for name in plan['skills']:
        stdout, stderr = out / (name + '.stdout'), out / (name + '.stderr')
        exits[name] = invoke(referee, [*common, '--scenario', name, '--spec-version', plan['spec_version'],
                                      '--force', '--output-dir', str(out / 'extensions')], stdout, stderr)
        logs[name] = stdout.read_text(errors='replace')
    (out / 'process-exits.json').write_text(json.dumps({'suite': suite_exit, 'skills': exits}, indent=2) + '\n')
    raw = receipts(out / 'results', plan['required'] + plan['tasks'] + plan['pending'])
    skills = receipts(out / 'extensions', plan['skills'])
    cases = evaluate(plan, raw, skills, (out / 'referee.stdout').read_text(errors='replace'), logs, suite_exit, exits)
    require(server_plan(coverage.load_plan(root)) == plan, 'Core requirements/checkout drift')
    (out / 'summary.json').write_text(json.dumps({'plan': plan, 'cases': cases}, indent=2) + '\n')
    report(cases)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('referee', type=Path)
    parser.add_argument('url')
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    try:
        return run(args.root.resolve(), args.referee.absolute(), args.url, args.out.resolve())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        print(f'Server coverage gate failed: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
