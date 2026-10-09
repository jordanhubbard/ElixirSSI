#!/usr/bin/env python3
"""Qualify the packaged Elixir installer and Phoenix workflow on disposable cards."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '_build/release'
ASSETS = OUT / 'assets'


def main():
    with tempfile.TemporaryDirectory(prefix='installed workspace-', dir=OUT) as directory:
        prefix = Path(directory) / 'ElixirSSI'
        name = 'elixirssi-' + hashlib.sha256(str(prefix).encode()).hexdigest()[:12]
        key = subprocess.check_output(['cksum'], input=str(prefix).encode()).decode().split()[0]
        manager = 'elixirssi-command-' + key
        env = dict(os.environ, SSI_NO_OPEN='1', SSI_COMMAND_PORT='4100', SSI_DESKTOP_PORT='4110')
        try:
            subprocess.run(['sh', str(ASSETS / 'install-elixirssi.command'), str(prefix)], check=True, env=env)
            if (prefix / 'desktop').exists() or (prefix / 'monitor.html').exists():
                raise RuntimeError('fresh install retained an obsolete external user interface')
            browser = OUT / 'browser'
            browser.mkdir(exist_ok=True)
            for file in ('package.json', 'package-lock.json'):
                shutil.copyfile(ROOT / 'os/scripts/browser' / file, browser / file)
            if not (browser / 'node_modules/playwright-core').exists():
                subprocess.run(['npm', 'ci', '--prefix', str(browser)], check=True)
            subprocess.run(['node', str(ROOT / 'scripts/distribution/browser-check.mjs'),
                            str(browser), str(prefix), str(OUT), manager], check=True, env=env)
            config = json.loads((prefix / 'installation.json').read_text())
            report = {'schema': 'elixirssi/installed-release-check@1', 'passed': True, 'nodes': 3,
                      'checks': ['offline-elixir-install', 'phoenix-authentication', 'three-board-membership',
                                 'project-edit-test-dependency-deploy', 'browser-desktop-input',
                                 'deployment-restart-persistence', 'stopped-cluster-workspace',
                                 'physical-node-registration', 'mobile-layout'],
                      'revision': config['revision'], 'version': config['version'],
                      'command_image': config['command_image'], 'runtime_image': config['image']}
            report_path = OUT / 'installed-check.json'
            report_path.write_text(json.dumps(report, indent=2) + '\n')
            manifest_path = OUT / 'files.json'
            manifest = json.loads(manifest_path.read_text())
            manifest['files'] = [item for item in manifest['files'] if item['role'] != 'installation-check']
            manifest['files'].append({'role': 'installation-check', 'path': report_path.relative_to(ROOT).as_posix(),
                                      'size': report_path.stat().st_size,
                                      'identity': 'sha256:' + hashlib.sha256(report_path.read_bytes()).hexdigest()})
            manifest.pop('identity', None)
            canonical = lambda value: json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
            manifest['identity'] = 'sha256:' + hashlib.sha256(canonical(manifest)).hexdigest()
            manifest_path.write_bytes(canonical(manifest) + b'\n')
            print('PASS: packaged Elixir installer and unified Phoenix workflow')
        finally:
            # These names derive only from this test's disposable installation.
            for container in (name, manager):
                subprocess.run(['docker', 'rm', '-f', container], stdout=subprocess.DEVNULL, check=False)
            subprocess.run(['docker', 'volume', 'rm', name + '-cards'], stdout=subprocess.DEVNULL, check=False)


if __name__ == '__main__':
    main()
