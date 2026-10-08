#!/usr/bin/env python3
"""Install the prebuilt ElixirSSI environment from adjacent or GitHub release assets."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import platform
import shutil
import secrets
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

VERSION = '@VERSION@'
REPOSITORY = 'jordanhubbard/ElixirSSI'


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def extract(archive, destination):
    with tarfile.open(archive) as tar:
        # Python 3.12+ data filtering refuses escaping paths and unsafe links.
        tar.extractall(destination, filter='data')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, default=Path.home() / 'ElixirSSI')
    parser.add_argument('--assets', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    if sys.version_info < (3, 12):
        parser.error('Python 3.12 or newer is required')
    if platform.system() not in ('Darwin', 'Linux') or platform.machine() not in ('arm64', 'aarch64'):
        parser.error('this installer requires Apple Silicon macOS or ARM64 Linux, Python 3.12+, and Docker')
    destination = args.prefix.expanduser().resolve()
    if destination.exists():
        parser.error('installation path already exists; choose a new --prefix to preserve existing data')
    subprocess.run(['docker', 'info'], stdout=subprocess.DEVNULL, check=True)
    base = f'https://github.com/{REPOSITORY}/releases/download/v{VERSION}/'
    with tempfile.TemporaryDirectory(prefix='elixirssi-download-') as tmp:
        downloads = Path(tmp)
        def asset(name):
            if Path(name).name != name or name in ('', '.', '..'):
                raise SystemExit('unsafe release asset name')
            local = args.assets / name
            if local.is_file():
                return local
            if args.offline:
                raise SystemExit(f'missing offline asset: {name}')
            path = downloads / name
            print('Downloading', name, flush=True)
            urllib.request.urlretrieve(base + name, path)
            return path
        manifest = json.loads(asset('installation.json').read_text())
        if manifest['version'] != VERSION:
            raise SystemExit('release manifest version differs from installer')
        selected = ['image', 'emulator', 'development', 'source', 'launcher', 'monitor',
                    'desktop-macos' if platform.system() == 'Darwin' else 'desktop-linux']
        paths = {}
        for role in selected:
            record = manifest['assets'][role]
            path = asset(record['name'])
            if sha(path) != record['sha256']:
                raise SystemExit(f'checksum mismatch: {path.name}')
            paths[role] = path
        for role in ('emulator', 'development'):
            subprocess.run(['docker', 'load', '-i', str(paths[role])], check=True)
        destination.parent.mkdir(parents=True, exist_ok=True)
        stage = Path(tempfile.mkdtemp(prefix='.elixirssi-install-', dir=destination.parent))
        try:
            (stage / 'image').mkdir()
            (stage / 'state').mkdir()
            with gzip.open(paths['image'], 'rb') as source, (stage / 'image/elixirssi-cm5.img').open('wb') as output:
                shutil.copyfileobj(source, output)
            extract(paths['source'], stage / 'source')
            extract(paths['desktop-' + ('macos' if platform.system() == 'Darwin' else 'linux')], stage / 'desktop-files')
            desktop_roots = list((stage / 'desktop-files').iterdir())
            if len(desktop_roots) != 1 or not (desktop_roots[0] / 'bin/remoteos-sdl').is_file():
                raise SystemExit('unexpected desktop archive layout')
            desktop_roots[0].rename(stage / 'desktop')
            (stage / 'desktop-files').rmdir()
            shutil.copyfile(paths['launcher'], stage / 'elixirssi')
            (stage / 'elixirssi').chmod(0o755)
            shutil.copyfile(paths['monitor'], stage / 'monitor.html')
            manifest['cluster_secret'] = secrets.token_hex(32)
            (stage / 'installation.json').write_text(json.dumps(manifest, indent=2) + '\n')
            (stage / 'installation.json').chmod(0o600)
            stage.rename(destination)
        except BaseException:
            shutil.rmtree(stage)
            raise
    print(f'Installed in {destination}')
    print(f'Run: {destination / "elixirssi"} start --nodes 3')
    print('The browser monitor remains available when all nodes stop.')
    print('Desktop runtime dependencies: macOS: brew install sdl2 sdl2_image sdl2_ttf ffmpeg;')
    print('ARM64 Debian/Ubuntu: install the SDL2, SDL2_image, SDL2_ttf and FFmpeg runtime packages.')
    print(f'Run {destination / "elixirssi"} desktop, then start --desktop host.docker.internal:17010 on Docker Desktop.')


if __name__ == '__main__':
    main()
