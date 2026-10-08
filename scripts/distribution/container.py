#!/usr/bin/env python3
"""Keep N prebuilt CM5 guests alive; retain their cards across container restarts."""
import os
from pathlib import Path
import signal
import subprocess
import time

os.chdir('/os')
count = int(os.environ.get('SSI_NODES', '3'))
if not 1 <= count <= 64:
    raise SystemExit('SSI_NODES must be between 1 and 64')
state = Path('/os/build/cm5emu')
state.mkdir(parents=True, exist_ok=True)
for pattern in ('node*.pid', 'node*.sock', 'node*.mon'):
    for path in state.glob(pattern):
        path.unlink()
runner = ['python3', 'scripts/ssi-cm5']
stop = False

def shutdown(*_):
    global stop
    stop = True

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)
try:
    for i in range(1, count + 1):
        subprocess.run([*runner, 'start', str(i)], check=True)
    print(f'{count} ElixirSSI boards started', flush=True)
    while not stop:
        time.sleep(1)
finally:
    subprocess.run([*runner, 'stop'], check=False)
