#!/usr/bin/env python3
"""End-to-end acceptance test for an ElixirSSI cluster under QEMU/KVM.

Boots N nodes with the shipped CM5 kernel and initramfs on a shared virtual
switch, drives their serial consoles, and checks that the machines behave as
one system: membership and aggregate resources, the cluster-wide process
table, one filesystem namespace, cluster-wide scheduling, service failover
when a VM is killed, rejoin with persistent state, and SSH into the shell.

With --desktop it also runs a headless RemoteOS-SDL service, checks that the
cluster desktop draws on it, captures PNGs, kills the node drawing the
desktop and verifies the desktop fails over to another node.

With --board cm5 the nodes are emulated Compute Module 5 boards instead
(scripts/ssi-cm5: BCM2712 + RP1, each booting its own copy of the flashable
image from eMMC, one RP1 Ethernet port each on a shared switch). The same
checks run, plus checks of the emulated hardware itself; SSH is tested
board to board, since a CM5 has no second port for host forwarding, and
the keyboard is a USB keyboard on RP1's xHCI.
"""
import argparse
import glob
import os
import pty
import re
import select
import socket
import subprocess
import sys
import threading
import time

OS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLUSTER = os.path.join(OS, "build", "cluster")
QEMU = os.path.join(OS, "scripts", "ssi-qemu")
BOOT_TIMEOUT = 120
REMOTEOS = os.environ.get("REMOTEOS_SDL", os.path.expanduser("~/Src/RemoteOS-SDL/remoteos-sdl"))
PROMPT = re.compile(rb"\(\d+\)> ")
results = []


def check(name, ok, detail=""):
    results.append((name, ok))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  -- ' + detail) if detail else ''}", flush=True)
    return ok


class Console:
    """A node's serial console over QEMU's chardev socket.

    A background thread drains the socket continuously: if nobody reads, QEMU
    stops draining the guest UART and the guest blocks in console writes,
    which stalls the kernel and the BEAM alike.
    """

    def __init__(self, index):
        self.index = index
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(os.path.join(CLUSTER, f"node{index}.sock"))
        self.buf = b""
        self.seq = 0
        self.cond = threading.Condition()
        self.closed = False
        threading.Thread(target=self._drain, daemon=True).start()

    def _drain(self):
        while not self.closed:
            try:
                chunk = self.sock.recv(65536)
            except OSError:
                break
            if not chunk:
                break
            with self.cond:
                self.buf = (self.buf + chunk)[-1_000_000:]
                self.cond.notify_all()

    def read_until(self, pattern, timeout):
        deadline = time.time() + timeout
        with self.cond:
            while True:
                m = pattern.search(self.buf)
                if m:
                    out, self.buf = self.buf[: m.end()], self.buf[m.end():]
                    return out
                left = deadline - time.time()
                if left <= 0:
                    raise TimeoutError(f"node {self.index}: no {pattern.pattern!r} within {timeout}s; tail={self.buf[-400:]!r}")
                self.cond.wait(min(left, 0.5))

    def ev(self, expr, timeout=60):
        """Evaluate an Elixir expression on this node; return inspect() of the result."""
        self.seq += 1
        tag = f"R{self.seq}N{self.index}"
        # Failures become values so a crashed call never strands the console.
        body = f"try do ({expr}) catch kind, reason -> {{:ev_error, kind, reason}} end"
        line = f'IO.puts("<" <> "{tag}>" <> inspect(({body}), limit: :infinity, printable_limit: :infinity) <> "</" <> "{tag}>")\n'
        pattern = re.compile(rf"<{tag}>(.*?)</{tag}>".encode(), re.S)
        with self.cond:
            self.buf = b""
        self.sock.sendall(line.encode())
        out = self.read_until(pattern, timeout)
        return pattern.search(out).group(1).decode(errors="replace")

    def close(self):
        self.closed = True
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


def qemu(*args):
    subprocess.run([QEMU, *map(str, args)], check=True, stdout=subprocess.DEVNULL)


def use_cm5():
    """Run every node as an emulated CM5 board (scripts/ssi-cm5)."""
    global CLUSTER, QEMU, BOOT_TIMEOUT
    # Acceptance tests reflash cards; keep them separate from interactive state.
    CLUSTER = os.path.join(os.environ.get("SSI_CM5_STATE_DIR", os.path.join(OS, "build", "cm5emu")), "tests")
    os.environ["SSI_CM5_STATE_DIR"] = CLUSTER
    QEMU = os.path.join(OS, "scripts", "ssi-cm5")
    BOOT_TIMEOUT = 300


def reset_node(index):
    """Discard this test node's cards and logs before a fresh acceptance run."""
    paths = [os.path.join(CLUSTER, f"node{index}{suffix}")
             for suffix in (".ext4", ".log", ".img")]
    paths += glob.glob(os.path.join(CLUSTER, f"node{index}-*.img"))
    for path in paths:
        if os.path.exists(path):
            os.remove(path)


def wait_log(index, text, timeout):
    path = os.path.join(CLUSTER, f"node{index}.log")
    subprocess.run([os.path.join(OS, "scripts", "waitlog"), path, text, str(timeout * 1000)], check=True)


def boot(index, endpoint=None):
    log = os.path.join(CLUSTER, f"node{index}.log")
    if os.path.exists(log):
        os.rename(log, log + f".{int(time.time())}")
    qemu("start", index, *( [endpoint] if endpoint else []))
    wait_log(index, "Type help", BOOT_TIMEOUT)
    return Console(index)


def eventually(fn, timeout=30, interval=0.5):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            last = fn()
            if last:
                return last
        except (TimeoutError, OSError) as e:
            last = e
        time.sleep(interval)
    return last


def sendkeys(index, keys):
    """Type on a node's virtual keyboard through its QEMU monitor (HMP sendkey)."""
    mon = socket.socket(socket.AF_UNIX)
    mon.connect(os.path.join(CLUSTER, f"node{index}.mon"))
    mon.settimeout(2)
    try:
        mon.recv(4096)  # banner
        for k in keys:
            mon.sendall(f"sendkey {k}\n".encode())
            time.sleep(0.05)
            try:
                mon.recv(4096)
            except socket.timeout:
                pass
    finally:
        mon.close()


def ssh_shell(port, password, command):
    """Log in over SSH with a password using a pty; return the command's output."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("ssh", ["ssh", "-p", str(port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                          "-o", "PubkeyAuthentication=no", "-o", "LogLevel=ERROR", "root@127.0.0.1"])
    buf = b""

    def until(pat, t=30):
        nonlocal buf
        deadline = time.time() + t
        while time.time() < deadline:
            m = re.search(pat, buf)
            if m:
                return m
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    buf += os.read(fd, 65536)
                except OSError:
                    break
        raise TimeoutError(f"ssh: no {pat!r}; got {buf[-300:]!r}")

    try:
        until(rb"assword:")
        os.write(fd, password.encode() + b"\n")
        until(PROMPT)
        start = len(buf)
        os.write(fd, command.encode() + b"\n")
        until(rb"<OUT>[^<]*</OUT>", 30)
        return buf[start:].decode(errors="replace")
    finally:
        os.kill(pid, 9)
        os.waitpid(pid, 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--nodes", type=int, default=3)
    ap.add_argument("--desktop", action="store_true")
    ap.add_argument("--keep", action="store_true", help="leave the cluster running")
    ap.add_argument("--board", choices=["virt", "cm5"], default="virt",
                    help="QEMU virt machines (KVM) or emulated CM5 boards")
    a = ap.parse_args()
    n = a.nodes
    cm5 = a.board == "cm5"
    if cm5:
        if a.desktop:
            ap.error("--desktop runs on virt nodes")
        use_cm5()
    os.makedirs(CLUSTER, exist_ok=True)
    qemu("stop")
    for i in range(1, n + 2):
        # A CM5 starts from a freshly flashed card
        reset_node(i)

    service = None
    endpoint = None
    if a.desktop:
        port = 17010
        env = dict(os.environ, REMOTEOS_SDL_MODE="headless", SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        service = subprocess.Popen([REMOTEOS, "--listen-tcp", f"127.0.0.1:{port}"], env=env,
                                   stdout=open(os.path.join(CLUSTER, "remoteos.log"), "w"), stderr=subprocess.STDOUT)
        endpoint = f"10.0.2.2:{port}"

    t0 = time.time()
    consoles = {}
    try:
        for i in range(1, n + 1):
            consoles[i] = boot(i, endpoint)
        c1 = consoles[1]
        check(f"{n} nodes booted to the Elixir shell", True, f"{time.time() - t0:.1f}s")
        if cm5:
            hardware_check(consoles, n)

        members = eventually(lambda: all(c.ev("length(SSI.Cluster.members())") == str(n) for c in consoles.values()), 60)
        check("every node sees the same membership", members is True)

        proto = c1.ev("Node.list() |> Enum.map(fn n -> {:ok, i} = :net_kernel.node_info(n); elem(i[:address], 3) end) |> Enum.uniq()")
        check("distribution between nodes is TLS", proto == "[:tls]", proto)

        summary = c1.ev("SSI.Cluster.summary() |> Map.take([:nodes, :cores])")
        check("aggregate machine reports all nodes and cores", summary == f"%{{nodes: {n}, cores: {4 * n}}}", summary)

        nodes_in_ps = c1.ev("SSI.Proc.ps() |> Enum.map(& &1.node) |> Enum.uniq() |> length()")
        check("process table spans every node", nodes_in_ps == str(n), nodes_in_ps)

        consoles[1].ev('SSI.FS.mkdir_p("/home/ada")')
        consoles[1].ev('SSI.FS.write("/home/ada/hello.txt", "written on node 1")')
        read = eventually(lambda: consoles[n].ev('SSI.FS.read("/home/ada/hello.txt")') == '{:ok, "written on node 1"}', 20)
        check("file written on node 1 is read on node N", read is True)
        proc = consoles[2].ev('SSI.FS.read("/proc/cluster") |> elem(1) |> String.contains?("nodes:      %d")' % n)
        check("/proc/cluster describes the whole cluster", proc == "true")

        used = c1.ev("SSI.Sched.pmap(1..400, fn _ -> node() end) |> Enum.uniq() |> length()", 120)
        check("cluster pmap runs on every node", used == str(n), used)

        bench = c1.ev("(fn -> {t, _} = :timer.tc(fn -> SSI.Sched.pmap(1..(4*%d), fn i -> Enum.count(1..150_000, &SSI.Shell.prime?(&1 + i)) end) end); div(t, 1000) end).()" % n, 300)
        check("distributed prime count completes", bench.isdigit(), f"{bench} ms")

        # Service failover: pin a counter to the last node, then kill that VM.
        last_node = consoles[n].ev("node()")
        c1.ev(f"SSI.Service.register(:counter, SSI.Demo.Counter, %{{}}, node: {last_node})")
        where = eventually(lambda: c1.ev("SSI.Service.call(:counter, :where, 2_000)") == last_node, 30)
        check("service starts on its pinned node", where is True)
        c1.ev("SSI.Demo.Counter.inc()")
        c1.ev("SSI.Demo.Counter.inc()")
        check("service counts to 2", c1.ev("SSI.Demo.Counter.inc()") == "3")
        consoles[n].close()
        qemu("stop", n)
        t_kill = time.time()
        where_now = lambda: c1.ev("SSI.Service.call(:counter, :where, 2_000)")
        moved = eventually(lambda: (lambda w: w.startswith(':"ssi@') and w != last_node)(where_now()), 60)
        check("killing the VM fails the service over", moved is True, f"{where_now()} after {time.time() - t_kill:.1f}s")
        check("service state survived the failover", c1.ev("SSI.Demo.Counter.inc()") == "4")
        shrunk = eventually(lambda: c1.ev("length(SSI.Cluster.members())") == str(n - 1), 30)
        check("membership shrinks after the failure", shrunk is True)

        # Rejoin: the node returns with its persistent store and sees the tree.
        consoles[n] = boot(n, endpoint)
        rejoined = eventually(lambda: c1.ev("length(SSI.Cluster.members())") == str(n), 60)
        check("restarted node rejoins the cluster", rejoined is True)
        saw = eventually(lambda: consoles[n].ev('SSI.FS.read("/home/ada/hello.txt")') == '{:ok, "written on node 1"}', 30)
        check("rejoined node sees the shared filesystem", saw is True)
        persisted = consoles[n].ev('File.exists?("/data/ssi/store.log") and SSI.Boot.persistent?()')
        check("node state is on its persistent data disk", persisted == "true")

        if cm5:
            ssh_between_boards(consoles, n)
        else:
            cmd = 'IO.puts("<" <> "OUT>" <> inspect(length(SSI.Cluster.members())) <> "</" <> "OUT>")'
            out = ""
            for _attempt in range(3):
                try:
                    out = ssh_shell(2222, "elixir", cmd)
                    break
                except TimeoutError as e:
                    out = str(e)
            m = re.search(r"<OUT>([^<]*)</OUT>", out)
            check("SSH login lands in the cluster shell", bool(m) and m.group(1) == str(n),
                  m.group(1) if m else out[-200:])

        running = c1.ev("Process.whereis(SSI.Console.TTY) != nil")
        check("a shell runs on the virtual console (tty1)", running == "true", running)
        sendkeys(1, ["n", "o", "d", "e", "shift-9", "shift-0", "ret"])
        vt = eventually(lambda: c1.ev('File.read!("/dev/vcs1") |> String.contains?(":\\"ssi@")') == "true", 20)
        check("typing node() on the keyboard evaluates it on tty1", vt is True,
              c1.ev('File.read!("/dev/vcs1") |> String.split(~r/ {4,}/, trim: true) |> Enum.take(-4)'))

        if a.desktop:
            desktop_check(consoles, n, endpoint)
    except Exception as e:  # noqa: BLE001 - report harness failures as test failures
        check("harness", False, repr(e))
    finally:
        for c in consoles.values():
            try:
                c.close()
            except OSError:
                pass
        if not a.keep:
            qemu("stop")
            if service:
                # SDL turns SIGTERM into a quit event that a service blocked in
                # accept() never reads; escalate if it does not exit promptly.
                service.terminate()
                try:
                    service.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    service.kill()

    failed = [name for name, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    return 1 if failed else 0


def hardware_check(consoles, n):
    """The emulated board, as Linux and the OS see it."""
    c = consoles[1]
    model = c.ev('File.read!("/proc/device-tree/model") |> String.trim_trailing(<<0>>)')
    check("the board is a Compute Module 5", model == '"Raspberry Pi Compute Module 5 Rev 1.0"', model)
    pci = c.ev('for f <- ~w(vendor device class revision), do: File.read!("/sys/bus/pci/devices/0002:01:00.0/" <> f) |> String.trim()')
    check("RP1 enumerates on PCIe2 as 1de4:0001 rev 2", pci == '["0x1de4", "0x0001", "0x020000", "0x02"]', pci)
    bars = c.ev('File.read!("/sys/bus/pci/devices/0002:01:00.0/resource") |> String.split("\\n") |> Enum.take(3) |> Enum.map(&hd(String.split(&1)))')
    check("RP1's BARs are where a Pi's firmware tree expects them", bars ==
          '["0x0000001f00410000", "0x0000001f00000000", "0x0000001f00400000"]', bars)
    irq = c.ev('File.read!("/proc/interrupts") |> String.split("\\n") |> Enum.find("", &String.contains?(&1, "eth0")) |> String.split() |> Enum.drop(5) |> Enum.join(" ")')
    check("eth0's interrupts arrive through RP1's MSI-X translation", irq == '"rp1_irq_chip 6 Level eth0"', irq)
    drv = c.ev('File.read!("/sys/class/net/eth0/device/uevent") |> String.contains?("DRIVER=macb")')
    check("eth0 is RP1's Cadence GEM (macb)", drv == "true", drv)
    emmc = c.ev('File.read!("/sys/block/mmcblk0/device/type") |> String.trim()')
    check("storage is the CM5's eMMC", emmc == '"MMC"', emmc)
    console = c.ev('Path.basename(File.read_link!("/sys/class/tty/ttyAMA0/device"))')
    check("the console UART is RP1's UART0 (GPIO 14/15)", console == '"1f00030000.serial:0.0"', console)
    kbd = c.ev('File.read!("/proc/bus/input/devices") |> String.contains?("QEMU USB Keyboard")')
    check("a USB keyboard enumerates on RP1's xHCI", kbd == "true", kbd)
    mounted = c.ev('File.read!("/proc/mounts") |> String.contains?("/dev/mmcblk0p2 /data ext4")')
    check("the data partition on eMMC is mounted read-write", mounted == "true", mounted)


def ssh_between_boards(consoles, n):
    """Log in over SSH from board 1 to board N across RP1's Ethernet."""
    target = consoles[n].ev("SSI.Net.cluster_address() |> elem(1) |> :inet.ntoa() |> to_string()")
    expr = ('(fn -> {:ok, ref} = :ssh.connect(String.to_charlist(%s), 22, user: ~c"root", password: ~c"elixir", '
            'silently_accept_hosts: true, save_accepted_host: false, user_interaction: false, connect_timeout: 15_000); '
            'v = :ssh.connection_info(ref, [:server_version]); :ssh.close(ref); v end).()') % target
    out = consoles[1].ev(expr, 60)
    check("SSH login from board 1 to board N", "server_version" in out, out[:120])


def desktop_check(consoles, n, endpoint):
    c1 = consoles[1]
    status = eventually(lambda: "connected: true" in c1.ev("SSI.Desktop.status()") and c1.ev("SSI.Desktop.status().frames > 5") == "true", 90)
    check("desktop service draws on RemoteOS-SDL", status is True, c1.ev("SSI.Desktop.status()"))
    shot1 = os.path.join(CLUSTER, "desktop-1.bmp")
    for p in (shot1, os.path.join(CLUSTER, "desktop-2.bmp")):
        if os.path.exists(p):
            os.remove(p)
    # Drive the desktop through RemoteOS input events: type into the Shell
    # window (focused by default), then click the Mandelbrot to zoom in.
    c1.ev('SSI.Desktop.type("Enum.sum(pmap(1..100, &(&1 * 2)))")')
    typed = eventually(lambda: c1.ev('SSI.Desktop.app_state(SSI.Desktop.ShellApp).lines |> Enum.any?(&(&1 == "10100"))') == "true", 30)
    check("typing in the Shell window evaluates across the cluster", typed is True)
    c1.ev("SSI.Desktop.click(941, 254)")
    zoomed = eventually(lambda: c1.ev("(fn s -> s.gen == 2 and s.elapsed != nil end).(SSI.Desktop.app_state(SSI.Desktop.MandelbrotApp))") == "true", 60)
    check("clicking the Mandelbrot re-renders it zoomed", zoomed is True)
    eventually(lambda: c1.ev("SSI.Desktop.status().frames > 40") == "true", 60)
    cap = c1.ev(f'SSI.Desktop.capture("{shot1}")')
    check("desktop frame captured", os.path.exists(shot1), cap)

    host_node = c1.ev("SSI.Desktop.status().node")
    victim = next(i for i, c in consoles.items() if c.ev("node()") == host_node)
    survivor = consoles[1 if victim != 1 else 2]
    consoles[victim].close()
    qemu("stop", victim)
    moved = eventually(lambda: (lambda s: "connected: true" in s and host_node not in s)(survivor.ev("SSI.Desktop.status()")), 90)
    check("desktop fails over to another node and reconnects", moved is True, survivor.ev("SSI.Desktop.status()"))
    restored = survivor.ev("SSI.Desktop.status().windows |> length()")
    check("desktop windows restored after failover", restored.isdigit() and int(restored) >= 3, restored)
    shell = survivor.ev('SSI.Desktop.app_state(SSI.Desktop.ShellApp).lines |> Enum.any?(&(&1 == "10100"))')
    check("shell window keeps its output across failover", shell == "true", shell)
    span = survivor.ev("SSI.Desktop.app_state(SSI.Desktop.MandelbrotApp).view.span < 3.2")
    check("Mandelbrot keeps its zoom across failover", span == "true", span)
    eventually(lambda: survivor.ev("SSI.Desktop.status().frames > 20") == "true", 60)
    shot2 = os.path.join(CLUSTER, "desktop-2.bmp")
    survivor.ev(f'SSI.Desktop.capture("{shot2}")')
    check("post-failover frame captured", os.path.exists(shot2))
    del consoles[victim]


if __name__ == "__main__":
    sys.exit(main())
