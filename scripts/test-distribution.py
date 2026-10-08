#!/usr/bin/env python3
"""Install the release assets and boot three boards, without building software."""
import hashlib
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / '_build/release/assets'


def get(port):
    with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/status', timeout=4) as response:
        return json.load(response)


def main():
    with tempfile.TemporaryDirectory(prefix='installed-', dir=ROOT / '_build/release') as directory:
        prefix = Path(directory) / 'ElixirSSI'
        subprocess.run([sys.executable, str(ASSETS / 'install-elixirssi.py'), '--assets', str(ASSETS),
                        '--offline', '--prefix', str(prefix)], check=True)
        cli = [sys.executable, str(prefix / 'elixirssi')]
        name = 'elixirssi-' + hashlib.sha256(str(prefix).encode()).hexdigest()[:12]
        desktop_log = (ROOT / '_build/release/installed-desktop.log').open('wb')
        desktop = subprocess.Popen([str(prefix / 'desktop/bin/remoteos-sdl'),'--listen-tcp','0.0.0.0:17019'],
            env=dict(os.environ,REMOTEOS_SDL_MODE='headless',SDL_VIDEODRIVER='dummy',SDL_AUDIODRIVER='dummy',
                     REMOTEOS_SDL_EXPORT_DIR=str(prefix)),stdout=desktop_log,stderr=subprocess.STDOUT)
        try:
            time.sleep(1)
            if desktop.poll() is not None:
                raise RuntimeError('packaged desktop failed to start; see installed-desktop.log')
            subprocess.run([*cli, 'start', '--nodes', '3', '--no-open',
                            '--desktop','host.docker.internal:17019'], check=True)
            deadline = time.monotonic() + 240
            while time.monotonic() < deadline:
                try:
                    snapshots = [get(8180+i) for i in (1,2,3)]
                    if all(s['schema'] == 'elixirssi-status/1' and s['system']['members'] == 3 for s in snapshots):
                        break
                except (OSError, ValueError):
                    pass
                time.sleep(3)
            else:
                raise RuntimeError('installed cluster did not form within 240 seconds')
            if (prefix / 'monitor.html').read_bytes() != (ASSETS / 'monitor.html').read_bytes():
                raise RuntimeError('installed offline monitor differs from release')
            with urllib.request.urlopen('http://127.0.0.1:8181/', timeout=4) as response:
                if b'WebSocket' not in response.read():
                    raise RuntimeError('member did not serve the management UI')
            capture = prefix / 'desktop.bmp'
            subprocess.run(['docker','exec','-i',name,'python3','-',str(capture)],
                           input=(ROOT / 'scripts/distribution/desktop-check.py').read_bytes(),check=True)
            if not capture.exists() or capture.stat().st_size < 1000:
                raise RuntimeError('desktop frame capture missing')
            shutil.copyfile(capture,ROOT / '_build/release/installed-desktop.bmp')
            config = json.loads((prefix / 'installation.json').read_text())
            subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/arm64',
                            config['builder'], 'elixir', '--version'], check=True)
            before = subprocess.check_output(['docker','exec',name,'sh','-c',
                                               'ls build/cm5emu/node*-*.img'], text=True)
            browser = ROOT / '_build/release/browser'
            browser.mkdir(exist_ok=True)
            for file in ('package.json', 'package-lock.json'):
                shutil.copyfile(ROOT / 'os/scripts/browser' / file, browser / file)
            if not (browser / 'node_modules/playwright-core').exists():
                subprocess.run(['npm','ci','--prefix',str(browser)],check=True)
            subprocess.run(['node',str(ROOT / 'scripts/distribution/browser-check.mjs'),
                            str(browser),str(prefix),str(ROOT / '_build/release'),sys.executable],check=True)
            if not (prefix / 'monitor.html').exists():
                raise RuntimeError('monitor disappeared with cluster shutdown')
            subprocess.run([*cli, 'start', '--nodes', '3', '--no-open'], check=True)
            time.sleep(5)
            after = subprocess.check_output(['docker','exec',name,'sh','-c',
                                              'ls build/cm5emu/node*-*.img'], text=True)
            if before != after:
                raise RuntimeError('restart replaced the persistent cards')
            report = {'schema':'elixirssi/installed-release-check@1', 'passed':True,
                      'nodes':3, 'checks':['offline-install','three-board-membership','served-management-ui',
                                          'offline-monitor','browser-healthy-down-reload','desktop-frames-and-capture','development-runtime','persistent-card-restart'],
                      'revision':config['revision'], 'version':config['version']}
            (ROOT / '_build/release/installed-check.json').write_text(json.dumps(report,indent=2)+'\n')
            manifest_path = ROOT / '_build/release/files.json'
            manifest = json.loads(manifest_path.read_text())
            report_path = ROOT / '_build/release/installed-check.json'
            manifest['files'] = [item for item in manifest['files'] if item['role'] != 'installation-check']
            manifest['files'].append({'role':'installation-check','path':report_path.relative_to(ROOT).as_posix(),
                                      'size':report_path.stat().st_size,
                                      'identity':'sha256:' + hashlib.sha256(report_path.read_bytes()).hexdigest()})
            del manifest['identity']
            canonical = lambda value: json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode()
            manifest['identity'] = 'sha256:' + hashlib.sha256(canonical(manifest)).hexdigest()
            manifest_path.write_bytes(canonical(manifest) + b'\n')
            print('PASS: installed three-board environment, management UI, development runtime and persistent cards')
        finally:
            subprocess.run(['docker','stop','-t','30',name], stdout=subprocess.DEVNULL, check=False)
            desktop.terminate()
            try:
                desktop.wait(timeout=5)
            except subprocess.TimeoutExpired:
                desktop.kill()
                desktop.wait()
            desktop_log.close()
            # Only this test's uniquely named disposable volume is removed.
            subprocess.run(['docker','volume','rm',name+'-cards'], stdout=subprocess.DEVNULL, check=False)


if __name__ == '__main__':
    main()
