#!/usr/bin/env python3
"""Project-owned Make suite and compact Literate AI receipt, not Standard generation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNNER = 'scripts/verify-project.py'
SUITE = 'elixirssi-system-image'
STAGES = ('build', 'test', 'test-emulator', 'test-cm5')
ARTIFACTS = ('os/build/cm5/elixirssi-cm5.img', 'os/build/cm5/elixirssi-cm5.img.zst')
RECEIPT = 'verification/current.json'
REPORT = 'verification/system-image.json'


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode() + b'\n'


def digest(content):
    return 'sha256:' + hashlib.sha256(content).hexdigest()


def file_digest(path):
    with path.open('rb') as stream:
        return 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()


def source_inventory(root):
    paths = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard',
         '--', 'Makefile', 'os', 'scripts'], cwd=root).decode().split('\0')
    result = {}
    for name in sorted(set(paths) - {''}):
        path = root / name
        if path.is_symlink():
            result[name] = {'link': os.readlink(path)}
        else:
            result[name] = {'identity': file_digest(path), 'executable': bool(path.stat().st_mode & 0o111)}
    if RUNNER not in result or 'Makefile' not in result:
        raise ValueError('source inventory is missing the runner or root Makefile')
    return result


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(canonical(value))
    temporary.replace(path)


def read_json(root, relative):
    return json.loads((root / relative).read_text())


def authority(root):
    completed = subprocess.run(['litai', 'project', 'validate'], cwd=root, capture_output=True, text=True)
    value = json.loads(completed.stdout)
    if completed.returncode or not value.get('ok'):
        raise ValueError('project authority validation failed: ' + completed.stdout + completed.stderr)
    return value['result']['authority_review']['authority_identity']


def policy(root):
    config = read_json(root, 'literate.project.json')
    selected = config['test_receipt_policy']
    pin = selected['runner_identity']
    if selected['suite_id'] != SUITE or selected['suite_version'] != '1.0.0':
        raise ValueError('project does not authorize this suite')
    if pin['algorithm'] + ':' + pin['digest'] != file_digest(root / RUNNER):
        raise ValueError('runner changed: review it and update its project policy pin')
    if selected['minimum_test_count'] != len(STAGES):
        raise ValueError('policy must require every suite stage')
    return config


def check(root):
    config = policy(root)
    report = read_json(root, REPORT)
    receipt = read_json(root, RECEIPT)
    if report['source'] != source_inventory(root):
        raise ValueError('retained source changed; run make verify-update')
    if receipt['subject'] != digest(canonical(report['source'])):
        raise ValueError('receipt source identity does not match the report')
    if receipt['result'] != digest(canonical(report)):
        raise ValueError('receipt report identity does not match')
    if [stage['target'] for stage in report['stages']] != list(STAGES) or any(
            stage['exit_code'] != 0 for stage in report['stages']):
        raise ValueError('verification suite is incomplete or failed')
    if receipt['tests'] != len(STAGES) or receipt['suite'] != {
            'id': SUITE, 'version': '1.0.0', 'revision': file_digest(root / RUNNER)}:
        raise ValueError('receipt suite does not match this runner')
    if receipt['project'] != config['project_id'] or receipt['project_revision'] != report['authority']:
        raise ValueError('receipt authority does not match the report')
    if receipt['evidence'] != evidence(root, report):
        raise ValueError('receipt evidence does not match the report')
    for name in ARTIFACTS:
        if report['artifacts'][name] != file_digest(root / name):
            raise ValueError('built image changed; run make verify-update')
    subprocess.run(['litai', 'verify'], cwd=root, check=True)


def evidence(root, report):
    return {
        'acceptance-result': digest(canonical(report['stages'][2:])),
        'build-result': digest(canonical(report['artifacts'])),
        'lifecycle-command': digest(canonical([['make', target] for target in STAGES])),
        'test-report': digest(canonical(report)),
        'test-runner': file_digest(root / RUNNER),
    }


def update(root):
    config = policy(root)
    # Invalidate a previous success before starting any new execution.
    (root / RECEIPT).unlink(missing_ok=True)
    revision = authority(root)
    subprocess.run(['litai', 'verify', '--gate', 'authority', '--gate', 'locks'], cwd=root, check=True)
    sources = source_inventory(root)
    logs = root / 'os/build/logs/verification'
    logs.mkdir(parents=True, exist_ok=True)
    stages = []
    for target in STAGES:
        log = logs / (target + '.log')
        print(f'Verifying make {target}; log: {log.relative_to(root)}', flush=True)
        with log.open('wb') as stream:
            result = subprocess.run(['make', target], cwd=root, stdout=stream, stderr=subprocess.STDOUT)
        if result.returncode:
            raise ValueError(f'make {target} failed ({result.returncode}); see {log}')
        stages.append({'target': target, 'exit_code': 0, 'log': log.relative_to(root).as_posix(),
                       'log_identity': file_digest(log)})
    if sources != source_inventory(root) or revision != authority(root):
        raise ValueError('source or authority changed during verification; no receipt published')
    report = {'schema': 'elixirssi/system-image-verification@1', 'authority': revision,
              'source': sources, 'stages': stages,
              'artifacts': {name: file_digest(root / name) for name in ARTIFACTS},
              'scope': 'Make suite on this host and three emulated CM5 boards; physical hardware unqualified'}
    receipt = {
        'schema': 'urn:literate-ai:schema:v1:project-test-receipt',
        'project': config['project_id'], 'project_revision': revision,
        'subject': digest(canonical(sources)),
        'suite': {'id': SUITE, 'version': '1.0.0', 'revision': file_digest(root / RUNNER)},
        'tests': len(STAGES), 'result': digest(canonical(report)), 'evidence': evidence(root, report),
    }
    atomic_json(root / REPORT, report)
    atomic_json(root / RECEIPT, receipt)
    try:
        check(root)
    except Exception:
        (root / RECEIPT).unlink(missing_ok=True)
        raise
    print('Verified all four stages and published the current system-image receipt.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--update', action='store_true', help='run the suite and replace the receipt after success')
    args = parser.parse_args()
    # Serialize both checks and publication on macOS/Linux, including separate Make invocations.
    import fcntl
    lock = ROOT / '_build/verification.lock'
    lock.parent.mkdir(exist_ok=True)
    with lock.open('w') as stream:
        fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        (update if args.update else check)(ROOT)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as exc:
        print(f'verification failed: {exc}', file=sys.stderr)
        sys.exit(1)
