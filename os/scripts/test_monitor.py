#!/usr/bin/env python3
"""End-to-end test of the cluster monitor in a real browser.

Boots N members (default 4) — emulated CM5 boards (scripts/ssi-cm5) or
QEMU/KVM virt nodes (scripts/ssi-qemu) — and opens the monitor page from a
file in headless Chromium, pointed at every member's web endpoint through
its management port. Then it puts the cluster through the states the
monitor exists to explain, checking what the page renders at each step:

  healthy -> a board's power pulled (degraded, failover with its downtime)
  -> the board back (healthy, previous boot unclean) -> a clean restart
  (previous boot clean) -> a partition into equal halves (split; only the
  half holding the roster's tie-breaker keeps quorum and runs the service,
  the other is fenced) -> the partition healed (healthy, one copy) -> every board off (down,
  last known state, kept across a reload) -> every board on (healthy
  again, without a reload).

Then a second browser, as an operator, opens the monitor over TLS (each
member's certificate verified against the cluster's web CA first): an
unauthenticated request is refused, the browser is paired with a code from a
shell, moves a service, restarts one member and powers off another, and
loses control when its key is revoked.

The browser is driven by scripts/browser/drive.mjs (playwright-core from
build/browser). Screenshots go to build/monitor-test/.
"""
import argparse
import base64
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_cluster as tc  # noqa: E402  (shared console, runner and check helpers)

OS = tc.OS
PAGE = os.path.join(OS, "ssi", "priv", "monitor", "index.html")
OUT = os.path.join(OS, "build", "monitor-test")
MODULES = os.path.join(OS, "build", "browser", "node_modules")


class Browser:
    """scripts/browser/drive.mjs, one JSON request and reply per line."""

    def __init__(self):
        env = dict(os.environ, SSI_BROWSER_MODULES=MODULES)
        self.proc = subprocess.Popen(["node", os.path.join(OS, "scripts", "browser", "drive.mjs")],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)

    def call(self, op, **args):
        self.proc.stdin.write(json.dumps({"op": op, **args}) + "\n")
        self.proc.stdin.flush()
        reply = json.loads(self.proc.stdout.readline())
        if not reply["ok"]:
            raise RuntimeError(f"browser {op}: {reply['error']}")
        return reply["value"]

    def wait(self, js, timeout):
        """True once `js` holds in the page, False if `timeout` seconds pass."""
        try:
            return self.call("wait", js=js, timeout=int(timeout * 1000))
        except RuntimeError:
            return False

    def eval(self, js):
        return self.call("eval", js=js)

    def quit(self):
        try:
            self.call("quit")
        except (BrokenPipeError, json.JSONDecodeError, RuntimeError):
            pass
        self.proc.wait(timeout=10)


# -- page predicates -----------------------------------------------------------

def verdict(state):
    return f'document.body.dataset.verdict === "{state}"'


def member(host, attr="state"):
    return f'(document.querySelector(\'[data-member="{host}"]\') || {{dataset: {{}}}}).dataset.{attr}'


def all_members(state, n):
    return (f'[...document.querySelectorAll("[data-member]")].filter(e => e.dataset.state === "{state}").length'
            f' === {n}')


def event(kind, subject, how=None):
    sel = f'#events li[data-kind="{kind}"][data-subject="{subject}"]' + (f'[data-how="{how}"]' if how else "")
    return f"document.querySelector('{sel}') !== null"


def text(selector):
    return f"(document.querySelector('{selector}') || {{innerText: ''}}).innerText"


# -- the cluster ---------------------------------------------------------------

def web_port(i, cm5):
    return (8180 if cm5 else 8080) + i


def tls_port(i, cm5):
    return (8480 if cm5 else 8440) + i


def status(i, cm5, timeout=5):
    with urllib.request.urlopen(f"http://127.0.0.1:{web_port(i, cm5)}/api/status", timeout=timeout) as r:
        return json.load(r)


def boot_id(i, cm5):
    try:
        return status(i, cm5)["observer"]["boot_id"]
    except (OSError, ValueError, KeyError):
        return None


def hmp(i, *commands):
    """Run HMP commands on a member's QEMU monitor; return what it printed."""
    mon = socket.socket(socket.AF_UNIX)
    mon.connect(os.path.join(tc.CLUSTER, f"node{i}.mon"))
    mon.settimeout(3)
    out = b""

    def prompt():
        buf = b""
        while not buf.rstrip().endswith(b"(qemu)"):
            buf += mon.recv(65536)
        return buf

    try:
        prompt()  # the banner
        for c in commands:
            mon.sendall((c + "\n").encode())
            out += prompt()  # the command has run when the next prompt appears
    finally:
        mon.close()
    return out.decode(errors="replace")


def member_cert(port, hostname, ca_pem):
    """A member's TLS certificate (PEM), after verifying it against the web CA for `hostname`."""
    ctx = ssl.create_default_context(cadata=ca_pem)
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        with ctx.wrap_socket(raw, server_hostname=hostname) as tls:
            return ssl.DER_cert_to_PEM_cert(tls.getpeercert(binary_form=True))


def ws_requests(port, make, timeout=10):
    """Send the messages `make(challenge)` on a member's stream; return the results."""
    s = socket.create_connection(("127.0.0.1", port), timeout=timeout)
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /api/stream HTTP/1.1\r\nhost: x\r\nupgrade: websocket\r\nconnection: Upgrade\r\n"
               f"sec-websocket-key: {key}\r\nsec-websocket-version: 13\r\n\r\n").encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(65536)
    buf = buf.split(b"\r\n\r\n", 1)[1]

    def message():
        nonlocal buf
        while True:
            if len(buf) >= 2:
                n, off = buf[1] & 0x7F, 2
                if n == 126:
                    n, off = (int.from_bytes(buf[2:4], "big"), 4) if len(buf) >= 4 else (None, 4)
                elif n == 127:
                    n, off = (int.from_bytes(buf[2:10], "big"), 10) if len(buf) >= 10 else (None, 10)
                if n is not None and len(buf) >= off + n:
                    payload, buf = buf[off:off + n], buf[off + n:]
                    return json.loads(payload)
            buf += s.recv(65536)

    def send(text):
        data, mask = text.encode(), os.urandom(4)
        head = bytes([0x81, 0x80 | len(data)]) if len(data) < 126 else bytes([0x81, 0x80 | 126]) + len(data).to_bytes(2, "big")
        s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    try:
        hello = message()
        msgs = make(hello["challenge"])
        for m in msgs:
            send(json.dumps(m))
        results = []
        while len(results) < len(msgs):
            m = message()
            if m["type"] == "result":
                results.append(m)
        return results
    finally:
        s.close()


def switch_b(cm5):
    group = os.environ.get("SSI_CM5_SWITCH" if cm5 else "SSI_SWITCH", "230.83.83.5:18355" if cm5 else "230.83.83.1:18350")
    host, port = group.rsplit(":", 1)
    a, b, c, d = host.split(".")
    # The next port too: a Linux multicast socket hears every group on its port.
    return f"{a}.{b}.{c}.{int(d) + 1}:{int(port) + 1}"


def start_all(indices):
    """Start members together (the emulated boards boot in parallel), then wait for each shell."""
    for i in indices:
        log = os.path.join(tc.CLUSTER, f"node{i}.log")
        if os.path.exists(log):
            os.rename(log, log + f".{int(time.time())}")
        tc.qemu("start", i)
    consoles = {}
    for i in indices:
        tc.wait_log(i, "Type help", tc.BOOT_TIMEOUT)
        consoles[i] = tc.Console(i)
    return consoles


def wait_rebooted(i, old, cm5, timeout):
    """Until member i answers with a boot id other than `old`."""
    return tc.eventually(lambda: (lambda b: b is not None and b != old)(boot_id(i, cm5)), timeout, 2)


def controls(consoles, hosts, n, cm5, boot_s):
    check = tc.check
    c1 = consoles[1]
    with urllib.request.urlopen(f"http://127.0.0.1:{web_port(1, cm5)}/ca.pem", timeout=5) as r:
        ca = r.read().decode()
    try:
        pems = {i: member_cert(tls_port(i, cm5), hosts[i], ca) for i in range(1, n + 1)}
        check("every member's TLS certificate verifies against the web CA for its host name", True)
    except (OSError, ssl.SSLError) as e:
        check("every member's TLS certificate verifies against the web CA for its host name", False, repr(e))
        return
    try:
        member_cert(tls_port(2, cm5), "not-" + hosts[2], ca)
        check("a certificate is refused for another name", False)
    except ssl.SSLCertVerificationError:
        check("a certificate is refused for another name", True)

    op = Browser()
    try:
        op.call("trust", pems=list(pems.values()))
        endpoints = ",".join(f"https://127.0.0.1:{tls_port(i, cm5)}" for i in range(1, n + 1))
        op.call("open", url=f"file://{PAGE}#endpoints={endpoints}")
        ok = op.wait(verdict("healthy") + " && " + all_members("up", n) +
                     f" && document.querySelectorAll('[data-endpoint][data-tls=\"true\"]').length === {n}", 60)
        check("the monitor connects to every member over TLS", ok, op.eval(text("#control-security")))
        paired = "document.getElementById('control-state').dataset.paired"
        check("unpaired, it is read-only: no controls offered",
              op.eval(paired) == "no" and op.eval("document.querySelectorAll('[data-act], [data-move]').length") == 0)

        # Reaching the port is not enough.
        svc = "(document.querySelector('[data-service=\"counter\"]') || {dataset: {}}).dataset.node"
        where = op.eval(svc)
        before = boot_id(1, cm5)
        forged = lambda ch: [  # noqa: E731
            {"type": "action", "request": json.dumps({"key": "AAAAAAAAAAAAAAAA", "seq": 1, "action": "poweroff", "member": hosts[1]}),
             "sig": base64.b64encode(os.urandom(64)).decode()},
            {"type": "action", "request": json.dumps({"key": "AAAAAAAAAAAAAAAA", "seq": 2, "action": "migrate", "service": "counter",
                                                      "to": hosts[2]})},
            {"type": "pair", "request": json.dumps({"seq": 3, "key": base64.urlsafe_b64encode(b"\x04" + os.urandom(64)).decode().rstrip("=")}),
             "mac": base64.b64encode(os.urandom(32)).decode()},
        ]
        replies = ws_requests(web_port(1, cm5), forged)
        try:
            urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:{web_port(1, cm5)}/api/status", data=b"", method="POST"), timeout=5)
            post = 200
        except urllib.error.HTTPError as e:
            post = e.code
        time.sleep(3)
        unchanged = boot_id(1, cm5) == before and op.eval(svc) == where and op.eval(paired) == "no"
        check("unauthenticated requests are refused and change nothing",
              [r["ok"] for r in replies] == [False] * 3 and post == 405 and unchanged,
              "; ".join(r.get("error", "") for r in replies) + f"; POST {post}")

        # Pairing with a code from a shell.
        code = c1.ev('SSI.Web.Control.pair("test operator")').strip('"')
        op.call("fill", selector="#pair-code", value=code)
        op.call("click", selector="#pair-form button")
        ok = op.wait(f"{paired} === 'yes'", 20)
        check("pairing with a one-time code from a shell", ok, op.eval(text("#control-state")))
        keys = c1.ev("SSI.Web.Control.keys() |> Enum.map(& &1.name)")
        check("every member trusts the key", keys == '["test operator"]' and
              all(c.ev("length(SSI.Web.Control.key_ids())") == "1" for c in consoles.values()), keys)

        # Move the service.
        where = op.eval(svc)
        to = next(hosts[i] for i in range(1, n + 1) if hosts[i] != where)
        op.call("select", selector='[data-move-select="counter"]', value=to)
        op.call("click", selector='[data-move="counter"]')
        ok = op.wait(f'{svc} === "{to}"', 60) and op.wait(
            "document.querySelector('#events li[data-kind=\"control\"][data-action=\"migrate\"][data-ok=\"true\"]') !== null", 10)
        check("moving a service from the monitor", ok, f"{where} -> {op.eval(svc)}; " + op.eval(text("#control-result")))

        # Restart a member: confirmed in the page first.
        third = hosts[3]
        old = boot_id(3, cm5)
        button = f'[data-act="restart"][data-target="{third}"]'
        op.call("click", selector=button)
        armed = op.eval(f"document.querySelector('{button}').innerText")
        op.call("click", selector=button)
        consoles.pop(3).close()
        if not cm5:
            tc.eventually(lambda: boot_id(3, cm5) is None, 60, 1)
            consoles.update(start_all([3]))
        else:
            wait_rebooted(3, old, cm5, boot_s)
            tc.wait_log(3, "Type help", boot_s)
            consoles[3] = tc.Console(3)
        ok = op.wait(verdict("healthy") + " && " + all_members("up", n), boot_s) and boot_id(3, cm5) not in (None, old)
        check("restarting a member from the monitor (after confirming)", ok and armed == "confirm restart",
              f"button read {armed!r}; " + op.eval(text("#control-result")))

        # Power off a member.
        last = hosts[n]
        button = f'[data-act="poweroff"][data-target="{last}"]'
        op.call("click", selector=button)
        op.call("click", selector=button)
        consoles.pop(n).close()
        ok = op.wait(f'{member(last)} === "missing"', 90)
        gone = tc.eventually(lambda: boot_id(n, cm5) is None, 30, 1)
        check("powering off a member from the monitor", ok and gone is True, op.eval(text("#control-result")))
        tc.qemu("stop", n)
        consoles.update(start_all([n]))
        ok = op.wait(verdict("healthy") + " && " + all_members("up", n) + f' && {member(last, "prevBoot")} === "clean"', boot_s)
        card = op.eval(text(f'[data-member="{last}"]'))
        check("it comes back reporting a clean power-off", ok and "cleanly (poweroff)" in card,
              " ".join(re.findall(r"ended [^\n]*", card)))
        journal = op.eval("[...document.querySelectorAll('#events li[data-kind=\"control\"]')].map(e => e.dataset.action).join(' ')")
        check("the timeline records each action and who took it", all(a in journal for a in ("pair", "migrate", "restart", "poweroff")), journal)
        op.call("shot", path=os.path.join(OUT, "7-controls.png"))

        # Revocation.
        c1.ev('SSI.Web.Control.revoke("test operator")')
        ok = op.wait(f"{paired} === 'revoked' && document.querySelectorAll('[data-act], [data-move]').length === 0", 15)
        check("revoking the key takes control away at once", ok, op.eval(text("#control-state")))
        problems = op.call("problems")
        check("no page errors in the operator's browser", problems == [], "; ".join(problems[:5]))
    finally:
        op.quit()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, default=4)
    ap.add_argument("--board", choices=["cm5", "virt"], default="cm5")
    ap.add_argument("--keep", action="store_true", help="leave the cluster running")
    a = ap.parse_args()
    n = a.nodes
    cm5 = a.board == "cm5"
    if n < 4:
        ap.error("the partition scenario needs at least 4 members")
    if cm5:
        tc.use_cm5()
        os.environ.setdefault("SSI_CM5_MEM", "2048")
    # How long a member takes to boot to its shell and to be noticed gone.
    boot_s = tc.BOOT_TIMEOUT
    os.makedirs(tc.CLUSTER, exist_ok=True)
    os.makedirs(OUT, exist_ok=True)
    tc.qemu("stop")
    for i in range(1, n + 2):
        for suffix in (".ext4", ".log", ".img"):
            p = os.path.join(tc.CLUSTER, f"node{i}{suffix}")
            if os.path.exists(p):
                os.remove(p)

    check = tc.check
    browser = Browser()
    consoles = {}
    t0 = time.time()
    try:
        consoles = start_all(range(1, n + 1))
        check(f"{n} members booted to the Elixir shell", True, f"{time.time() - t0:.1f}s")
        c1 = consoles[1]
        formed = tc.eventually(lambda: all(c.ev("length(SSI.Cluster.members())") == str(n) for c in consoles.values()), 120)
        check("every member sees the same membership", formed is True)
        hosts = {i: c.ev("SSI.Boot.hostname()").strip('"') for i, c in consoles.items()}

        # -- the endpoint, then the page served by a member ------------------------
        served = [status(i, cm5)["observer"]["hostname"] for i in range(1, n + 1)]
        check("every member serves its status endpoint", served == [hosts[i] for i in range(1, n + 1)], str(served))
        browser.call("open", url=f"http://127.0.0.1:{web_port(1, cm5)}/")
        ok = browser.wait(verdict("healthy") + " && " + all_members("up", n), 60)
        check("the page served by a member shows the cluster healthy", ok, browser.eval(text("#reasons")))

        # -- the page from a file, connected to every member -------------------------
        endpoints = ",".join(f"127.0.0.1:{web_port(i, cm5)}" for i in range(1, n + 1))
        browser.call("open", url=f"file://{PAGE}#endpoints={endpoints}")
        ok = browser.wait(verdict("healthy") + " && " + all_members("up", n) +
                          f' && document.querySelectorAll(\'[data-endpoint][data-status="live"]\').length === {n}', 60)
        check("the monitor from a file connects to every member: healthy", ok, browser.eval(text("#reasons")))
        cores = browser.eval(text('[data-fact="cores"] b'))
        check("the system view is the aggregate machine", cores == str(4 * n), f"{cores} cores")
        browser.call("shot", path=os.path.join(OUT, "1-healthy.png"))

        # -- a power pull ----------------------------------------------------------
        last = hosts[n]
        c1.ev(f'SSI.Service.register(:counter, SSI.Demo.Counter, %{{}}, node: :"{status(n, cm5)["observer"]["node"]}")')
        c1.ev("SSI.Demo.Counter.inc()")
        ok = browser.wait(f'(document.querySelector(\'[data-service="counter"]\') || {{dataset: {{}}}}).dataset.node === "{last}"', 60)
        check("the services view shows where a service runs", ok)
        consoles.pop(n).close()
        tc.qemu("stop", n)
        t_pull = time.time()
        ok = browser.wait(verdict("degraded") + f' && {member(last)} === "missing"', 60)
        check("pulling a board's power: degraded, the board missing", ok,
              f"{time.time() - t_pull:.1f}s; " + browser.eval(text("#reasons")).replace("\n", "; "))
        st = browser.eval(f'document.querySelector(\'[data-endpoint="127.0.0.1:{web_port(n, cm5)}"]\').dataset.status')
        check("its endpoint is reported as not answering", st in ("refused", "timeout", "lost", "failed"), st)
        ok = browser.wait(event("service_started", "counter", "failover"), 90)
        line = browser.eval(f"(document.querySelector('#events li[data-how=\"failover\"]') || {{innerText: ''}}).innerText")
        check("the timeline shows the failover and how long the service was unavailable", ok and "unavailable" in line, line)
        browser.call("shot", path=os.path.join(OUT, "2-power-pulled.png"))

        # -- the board back: its previous boot ended uncleanly ------------------------
        consoles.update(start_all([n]))
        ok = browser.wait(verdict("healthy") + " && " + all_members("up", n) +
                          f' && {member(last, "prevBoot")} === "unclean"', boot_s)
        check("the board returns: healthy, previous boot ended uncleanly", ok, browser.eval(text("#reasons")))
        check("the timeline shows the board's boot", browser.eval(event("member_booted", last)))

        # -- a clean restart ----------------------------------------------------------
        third = hosts[3]
        old = boot_id(3, cm5)
        restarting = consoles.pop(3)
        restarting.ev("SSI.Power.restart()")
        restarting.close()
        if not cm5:
            # virt nodes run with -no-reboot: the VM exits and is started again.
            tc.eventually(lambda: boot_id(3, cm5) is None, 60, 1)
            consoles.update(start_all([3]))
        else:
            wait_rebooted(3, old, cm5, boot_s)
            tc.wait_log(3, "Type help", boot_s)
            consoles[3] = tc.Console(3)
        ok = browser.wait(verdict("healthy") + " && " + all_members("up", n) +
                          f' && {member(third, "prevBoot")} === "clean"', boot_s)
        card = browser.eval(text(f'[data-member="{third}"]'))
        check("a clean restart is reported as such", ok and "cleanly (restart)" in card,
              " ".join(re.findall(r"ended [^\n]*", card)))

        # -- a partition: {1..n-2} | {n-1, n} ------------------------------------------
        side = [n - 1, n]
        t_split = time.time()
        for i in side:
            out = hmp(i, f"netdev_add socket,id=swb,mcast={switch_b(cm5)}", "netdev_add hubport,id=pb,hubid=0,netdev=swb",
                      "set_link swa off")
            if "Error" in out:
                raise RuntimeError(f"member {i}: {out}")
        ok = browser.wait(verdict("split"), 120)
        reasons = browser.eval(text("#reasons"))
        check("a partition is shown as a split with both groups", ok and "group 2" in reasons,
              f"{time.time() - t_split:.1f}s; " + reasons.replace("\n", "; "))
        # The larger group holds quorum; of equal halves (four members), the
        # one with the lowest host name, the roster's tie-breaker. It runs the
        # service; the other is fenced.
        halves = [[hosts[i] for i in range(1, n - 1)], [hosts[i] for i in side]]
        winner = max(halves, key=lambda h: (len(h), h is min(halves, key=min)))
        loser = halves[1] if winner is halves[0] else halves[0]
        where = "(document.querySelector('[data-service=\"counter\"]') || {dataset: {node: ''}}).dataset.node"
        one_copy = f'{where} !== "" && {where}.split(" ").length === 1 && {json.dumps(winner)}.includes({where})'
        fenced = " && ".join(f'(document.querySelector(\'[data-member="{h}"] [data-fenced]\') || {{dataset: {{}}}}).dataset.fenced === "{v}"'
                             for h, v in [(h, "no") for h in winner] + [(h, "yes") for h in loser])
        ok = browser.wait(one_copy + " && " + fenced, 60)
        reasons = browser.eval(text("#reasons"))
        check("only the half holding quorum runs the service; the other is shown fenced",
              ok and f"holds quorum ({len(winner)} of {n})" in reasons and f"no quorum ({len(loser)} of {n})" in reasons,
              f"{browser.eval(where)} in {'+'.join(winner)}; " + reasons.replace("\n", "; "))
        # Sampled while the partition lasts: never a second copy, never none.
        copies = set()
        t_hold = time.time()
        while time.time() - t_hold < 20:
            copies.add(browser.eval(where) if browser.eval(verdict("split")) else "(not split)")
            time.sleep(1)
        check("the split holds with exactly one copy of the service, on the quorum side",
              all(c in winner for c in copies), ", ".join(sorted(copies)))
        ok = browser.wait(event("quorum", loser[0]), 10)
        check("the timeline shows the fenced half losing quorum", ok)
        browser.call("shot", path=os.path.join(OUT, "3-split.png"))

        t_heal = time.time()
        for i in side:
            out = hmp(i, "set_link swa on", "netdev_del pb", "netdev_del swb")
            if "Error" in out:
                raise RuntimeError(f"member {i}: {out}")
        ok = browser.wait(verdict("healthy") + ' && (document.querySelector(\'[data-service="counter"]\') || {dataset: {}}).dataset.node.split(" ").length === 1', 120)
        check("healing the partition: healthy, one copy of the service", ok, f"{time.time() - t_heal:.1f}s")

        # -- every board off --------------------------------------------------------------
        for c in consoles.values():
            c.close()
        consoles = {}
        tc.qemu("stop")
        t_down = time.time()
        ok = browser.wait(verdict("down") + " && " + all_members("missing", n), 60)
        check("every board off: down, every member missing", ok,
              f"{time.time() - t_down:.1f}s; " + browser.eval(text("#reasons")).replace("\n", "; "))
        cores = browser.eval(text('[data-fact="cores"] b'))
        check("the last known machine is still shown", cores == str(4 * n), f"{cores} cores (last known)")
        browser.call("shot", path=os.path.join(OUT, "4-down.png"))
        browser.call("reload")
        ok = browser.wait(verdict("down") + " && " + all_members("missing", n) + " && " +
                          event("service_started", "counter", "failover"), 30)
        check("after a reload with nothing answering, the last known cluster and timeline remain", ok)

        # -- every board on again ------------------------------------------------------------
        t_up = time.time()
        consoles = start_all(range(1, n + 1))
        ok = browser.wait(verdict("healthy") + " && " + all_members("up", n), 180)
        check("the monitor follows the cold start back to healthy without a reload", ok, f"{time.time() - t_up:.1f}s")
        unclean = browser.eval('[...document.querySelectorAll("[data-member]")].filter(e => e.dataset.prevBoot === "unclean").length')
        check("after the power cut every member reports an unclean previous boot", unclean == n, str(unclean))
        browser.call("shot", path=os.path.join(OUT, "5-recovered.png"))

        # -- controls, over TLS, from an operator's browser ---------------------------------------
        controls(consoles, hosts, n, cm5, boot_s)

        # -- presentation -----------------------------------------------------------------------
        browser.call("viewport", width=390, height=844)
        width = browser.eval("[document.documentElement.scrollWidth, window.innerWidth]")
        check("no horizontal overflow on a phone-sized viewport", width[0] <= width[1], str(width))
        browser.call("shot", path=os.path.join(OUT, "6-phone.png"))
        problems = browser.call("problems")
        check("no page errors or unexpected console errors", problems == [], "; ".join(problems[:5]))
    except Exception as e:  # noqa: BLE001 - report harness failures as test failures
        check("harness", False, repr(e))
    finally:
        browser.quit()
        for c in consoles.values():
            try:
                c.close()
            except OSError:
                pass
        if not a.keep:
            tc.qemu("stop")

    failed = [name for name, ok in tc.results if not ok]
    print(f"\n{len(tc.results) - len(failed)}/{len(tc.results)} checks passed; screenshots in {OUT}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
