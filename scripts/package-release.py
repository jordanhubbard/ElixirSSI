#!/usr/bin/env python3
"""Build downloadable, checksum-bound artifacts for the exact release checkout."""
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / '_build/release/assets'
DIST = ROOT / 'scripts/distribution'


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, check=True, **kwargs)


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def export_image(image, path):
    identity = subprocess.check_output(['docker', 'image', 'inspect', '--format', '{{.Id}}', image], text=True).strip()
    pin = path.with_suffix(path.suffix + '.identity')
    if path.exists() and pin.exists() and pin.read_text() == identity:
        return
    with path.with_suffix('.partial').open('wb') as raw:
        process = subprocess.Popen(['docker', 'save', image], stdout=subprocess.PIPE)
        try:
            with gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as output:
                shutil.copyfileobj(process.stdout, output)
        finally:
            process.stdout.close()
        if process.wait() != 0:
            raise RuntimeError('docker save failed')
    path.with_suffix('.partial').replace(path)
    pin.write_text(identity)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    version = json.loads((ROOT / 'literate.project.json').read_text())['version']
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    runtime = 'elixirssi-runtime:' + version
    builder = 'elixirssi-builder:otp29.1.1-ex1.20.4'
    command = 'elixirssi-command:' + version
    run('docker', 'build', '-t', command, str(ROOT / 'command'))
    export_image(command, OUT / 'elixirssi-command-linux-arm64.tar.gz')
    boot_config = subprocess.check_output(['docker','run','--rm','-v',f'{ROOT / "os"}:/os:ro',
        '-e','MTOOLS_SKIP_CHECK=1',builder,'mtype','-i','/os/build/cm5/elixirssi-cm5.img@@4M','::/ssi.conf'],text=True)
    if 'secret = elixirssi-insecure-default-secret' not in boot_config.splitlines():
        raise RuntimeError('release image must use the warned public default; run make release-image first')
    key = subprocess.check_output(['bash', '-c', 'printf %s "$1" | cksum', 'sh', str(ROOT / 'os')], text=True).split()[0]
    context = ROOT / '_build/release/runtime'
    context.mkdir(parents=True, exist_ok=True)
    run('docker', 'run', '--rm', '-v', f'elixirssi-emulator-{key}:/emulator:ro',
        '-v', f'{context}:/export', 'elixirssi-emulator:bookworm', 'sh', '-c',
        'mkdir -p /export/emulator/build /export/emulator/scripts; '
        'cp /emulator/current/build/qemu-system-aarch64 /export/emulator/build/; '
        'cp /emulator/current/scripts/rpi5-boot /export/emulator/scripts/; '
        'cp /emulator/current/LICENSE /export/emulator/LICENSE')
    for source, name in [(DIST / 'runtime.Dockerfile', 'Dockerfile'),
                         (DIST / 'emulator.exs', 'emulator.exs')]:
        shutil.copyfile(source, context / name)
    run('docker', 'build', '-t', runtime, str(context))
    export_image(runtime, OUT / 'elixirssi-emulator-linux-arm64.tar.gz')
    export_image(builder, OUT / 'elixirssi-development-linux-arm64.tar.gz')
    raw = ROOT / 'os/build/cm5/elixirssi-cm5.img'
    image = OUT / 'elixirssi-pi5-cm5.img.gz'
    with raw.open('rb') as source, image.open('wb') as target:
        with gzip.GzipFile(fileobj=target, mode='wb', mtime=0) as compressed:
            shutil.copyfileobj(source, compressed)
    with tarfile.open(OUT / 'elixirssi-source.tar.gz', 'w:gz') as tar:
        files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).decode().split('\0')
        for name in sorted(set(files) - {''}):
            if (ROOT / name).exists():
                tar.add(ROOT / name, arcname=name, recursive=False)
    # Corresponding upstream source, including the applied emulator patches.
    run('docker', 'run', '--rm', '-v', f'elixirssi-emulator-{key}:/emulator:ro',
        '-v', f'elixirssi-kernel-{key}:/kernel:ro', '-v', f'{OUT}:/export',
        'elixirssi-emulator:bookworm', 'sh', '-c',
        'tar -C /emulator/current --exclude=.git --exclude=build --exclude=__pycache__ '
        '-czf /export/elixirssi-emulator-source.tar.gz LICENSE scripts qemu overlay patches series; '
        'tar -C /kernel/src --exclude=.git -czf /export/elixirssi-kernel-source.tar.gz .')
    shutil.copyfile(DIST / 'elixirssi.command', OUT / 'elixirssi')
    (OUT / 'install-elixirssi.command').write_text((DIST / 'install-elixirssi.command').read_text().replace('@VERSION@', version))
    (OUT / 'install-elixirssi.command').chmod(0o755)
    roles = {
        'image': image.name, 'emulator': 'elixirssi-emulator-linux-arm64.tar.gz',
        'development': 'elixirssi-development-linux-arm64.tar.gz', 'source': 'elixirssi-source.tar.gz',
        'emulator-source': 'elixirssi-emulator-source.tar.gz', 'kernel-source': 'elixirssi-kernel-source.tar.gz',
        'installer': 'install-elixirssi.command', 'launcher': 'elixirssi',
        'command': 'elixirssi-command-linux-arm64.tar.gz',
    }
    installation = {'version': version, 'revision': revision, 'image': subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',runtime], text=True).strip(),
                    'command_image': subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',command], text=True).strip(),
                    'builder': subprocess.check_output(['docker','image','inspect','--format','{{.Id}}',builder], text=True).strip(),
                    'assets': {role: {'name': name, 'sha256': digest(OUT / name)} for role, name in roles.items()},
                    'physical_hardware': 'Pi 5 and CM5 targeted; physical boot not yet qualified'}
    (OUT / 'installation.json').write_text(json.dumps(installation, indent=2) + '\n')
    roles['installation'] = 'installation.json'
    (OUT / 'SHA256SUMS').write_text(''.join(f'{digest(OUT / name)}  {name}\n' for name in roles.values()))
    roles['checksums'] = 'SHA256SUMS'
    manifest = {'schema': 'literate-ai/qualified-release-files@1', 'revision': revision, 'version': version,
                'files': [{'role': role, 'path': (OUT / name).relative_to(ROOT).as_posix(),
                           'size': (OUT / name).stat().st_size, 'identity': 'sha256:' + digest(OUT / name)}
                          for role, name in roles.items()]}
    manifest['identity'] = 'sha256:' + hashlib.sha256(canonical(manifest)).hexdigest()
    (ROOT / '_build/release/files.json').write_bytes(canonical(manifest) + b'\n')
    print('Release assets:', OUT)


if __name__ == '__main__':
    main()
