#!/usr/bin/env python3
"""Run inside the installed emulator container to qualify desktop drawing."""
import re
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.settimeout(1)
sock.connect('/os/build/cm5emu/node1.sock')

def evaluate(expression):
    marker = 'RELEASE_DESKTOP_RESULT'
    sock.sendall(('IO.puts("<' + marker + '>" <> inspect(' + expression + ') <> "</' + marker + '>")\n').encode())
    data = b''
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        try:
            data += sock.recv(65536)
        except TimeoutError:
            continue
        matches = re.findall(rb'<RELEASE_DESKTOP_RESULT>([^\r\n]*?)</RELEASE_DESKTOP_RESULT>',data)
        for match in matches:
            if b'inspect(' not in match:
                return match.decode()
    raise RuntimeError('guest console did not return desktop result')

end = time.monotonic() + 90
while time.monotonic() < end:
    if evaluate('case SSI.Desktop.status() do %{connected: true, frames: n} when n > 5 -> true; _ -> false end') == 'true':
        print(evaluate('SSI.Desktop.capture(' + repr(sys.argv[1]).replace("'", '"') + ')'))
        break
    time.sleep(2)
else:
    raise RuntimeError('installed desktop did not produce frames')
sock.close()
