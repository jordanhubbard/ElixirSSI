#!/usr/bin/env python3
"""Start and manage an installed ElixirSSI cluster; no OS or emulator compilation."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import webbrowser

ROOT = Path(__file__).resolve().parent
CONFIG = json.loads((ROOT / 'installation.json').read_text())
NAME = 'elixirssi-' + hashlib.sha256(str(ROOT).encode()).hexdigest()[:12]


def docker(*args, **kwargs):
    return subprocess.run(['docker', *args], check=True, **kwargs)


def monitor(nodes, launch=True):
    url = (ROOT / 'monitor.html').as_uri() + '#endpoints=' + ','.join(f'localhost:{8180+i}' for i in range(1, nodes+1))
    print(url)
    if launch:
        webbrowser.open(url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    start = commands.add_parser('start')
    start.add_argument('--nodes', type=int, default=3)
    start.add_argument('--memory', type=int, default=4096, help='MiB per emulated board')
    start.add_argument('--no-open', action='store_true')
    start.add_argument('--desktop', help='RemoteOS-SDL host:port reachable from the container; use host.docker.internal:17010 on Docker Desktop')
    commands.add_parser('stop')
    commands.add_parser('status')
    commands.add_parser('monitor')
    commands.add_parser('dev')
    commands.add_parser('test')
    desktop = commands.add_parser('desktop')
    desktop.add_argument('--listen', default='0.0.0.0:17010', help='bind address for guest desktop connections; use a trusted network')
    args = parser.parse_args()
    if args.command == 'start':
        if not 1 <= args.nodes <= 64 or args.memory < 512:
            parser.error('nodes must be 1..64; memory must be at least 512 MiB per board')
        ports = []
        for i in range(1, args.nodes + 1):
            for base in (8180, 8480, 2320):
                ports += ['-p', f'127.0.0.1:{base+i}:{base+i}']
        host_args = [] if sys.platform == 'darwin' else ['--add-host', 'host.docker.internal:host-gateway']
        extra = 'ssi.ssh.password=elixir ssi.secret=' + CONFIG['cluster_secret']
        if args.desktop:
            if any(c.isspace() for c in args.desktop):
                parser.error('desktop must be one host:port')
            # Resolve the host within the container before giving Linux a numeric address.
            resolved = subprocess.check_output(['docker', 'run', '--rm', *host_args, CONFIG['image'], 'python3', '-c',
                'import socket,sys; print(socket.gethostbyname(sys.argv[1]))', args.desktop.rsplit(':',1)[0]], text=True).strip()
            extra += ' ssi.desktop=' + resolved + ':' + args.desktop.rsplit(':',1)[1]
        docker('run', '-d', '--rm', '--init', '--name', NAME, *host_args,
               '--platform', 'linux/arm64', '-e', f'SSI_NODES={args.nodes}',
               '-e', f'SSI_CM5_MEM={args.memory}', '-e', 'SSI_CM5_APPEND=' + extra,
               '-v', f'{ROOT / "image"}:/os/build/cm5:ro',
               '-v', f'{NAME}-cards:/os/build/cm5emu', *ports, CONFIG['image'])
        (ROOT / 'last-nodes').write_text(str(args.nodes))
        monitor(args.nodes, not args.no_open)
    elif args.command == 'stop':
        docker('stop', '-t', '30', NAME)
    elif args.command == 'status':
        docker('ps', '-a', '--filter', 'name=^/' + NAME + '$')
    elif args.command == 'monitor':
        monitor(int((ROOT / 'last-nodes').read_text()) if (ROOT / 'last-nodes').exists() else 3)
    elif args.command in ('dev', 'test'):
        terminal = ['-it'] if args.command == 'dev' else []
        command = ['bash'] if args.command == 'dev' else ['sh','-c',
            'epmd -daemon; MIX_ENV=test elixir --name ssi-test@127.0.0.1 -S mix test']
        docker('run', '--rm', *terminal, '--platform', 'linux/arm64',
               '--user', f'{os.getuid()}:{os.getgid()}', '-e', 'HOME=/tmp', '-e', 'MIX_HOME=/tmp/mix',
               '-v', f'{ROOT / "source/os"}:/os', '-w', '/os/ssi', CONFIG['builder'], *command)
    elif args.command == 'desktop':
        binary = ROOT / 'desktop/bin/remoteos-sdl'
        if not binary.exists():
            parser.error('desktop package not installed for this host')
        subprocess.run([str(binary), '--listen-tcp', args.listen], check=True)
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
