#!/usr/bin/env python3
"""Assemble the ElixirSSI initramfs.

The archive is the whole root filesystem. It is generated with the kernel's
own usr/gen_init_cpio from a manifest, so every entry is owned by root and
device nodes exist without the build needing root privileges.

    /init                     static PID-1 shim (execs the BEAM)
    /ssi/                     Elixir release: ERTS, OTP, Elixir, SSI
    /lib, /usr/lib            musl loader and the libraries ERTS links
    /usr/share/terminfo       terminal descriptions for the shell
    /lib/modules/KVER/        curated kernel modules + filtered indexes
"""
import argparse
import os
import re
import subprocess
import sys

# Driver trees a headless compute node may need. Graphics, sound, media,
# wireless and bluetooth are left out: the console is serial or SSH, and the
# desktop is drawn remotely over RemoteOS.
MODULE_PREFIXES = (
    "kernel/drivers/net/ethernet/", "kernel/drivers/net/phy/", "kernel/drivers/net/mdio/",
    "kernel/drivers/net/usb/", "kernel/drivers/net/pcs/", "kernel/drivers/net/vxlan/",
    "kernel/drivers/net/macvlan", "kernel/drivers/net/tun", "kernel/drivers/net/veth",
    "kernel/drivers/net/dummy", "kernel/drivers/net/bonding/", "kernel/drivers/net/team/",
    "kernel/drivers/usb/", "kernel/drivers/mmc/", "kernel/drivers/nvme/", "kernel/drivers/ata/",
    "kernel/drivers/scsi/", "kernel/drivers/block/", "kernel/drivers/md/",
    "kernel/drivers/hwmon/", "kernel/drivers/thermal/", "kernel/drivers/watchdog/",
    "kernel/drivers/gpio/", "kernel/drivers/i2c/", "kernel/drivers/spi/", "kernel/drivers/pwm/",
    "kernel/drivers/rtc/", "kernel/drivers/input/", "kernel/drivers/hid/",
    "kernel/drivers/char/", "kernel/drivers/mfd/", "kernel/drivers/misc/", "kernel/drivers/pinctrl/",
    "kernel/drivers/firmware/", "kernel/drivers/nvmem/", "kernel/drivers/leds/", "kernel/drivers/iio/",
    "kernel/drivers/pps/", "kernel/drivers/ptp/", "kernel/drivers/dma/", "kernel/drivers/regulator/",
    "kernel/drivers/clk/", "kernel/drivers/reset/", "kernel/drivers/phy/", "kernel/drivers/power/",
    "kernel/fs/", "kernel/net/", "kernel/crypto/", "kernel/lib/", "kernel/arch/",
)
EXCLUDE = re.compile(
    r"/(wireless|bluetooth|nfc|wimax|can|ieee802154|mac80211|cfg80211|sound|media|gpu|drm)/"
    r"|/fs/(xfs|btrfs|ocfs2|gfs2|smb|nfsd|ceph|jfs|nilfs2|dlm|orangefs|coda|afs|9p|ntfs3|udf|hfsplus|hfs|reiserfs)/"
    r"|/usb/(serial|gadget|misc|image|atm)/|/block/drbd/|/net/(ceph|sunrpc/xprtrdma|rds|tipc|sctp|dccp)/"
)


def walk(root):
    for base, _dirs, files in os.walk(root):
        for name in sorted(files):
            yield os.path.join(base, name)


def module_subset(moddir):
    """Return (kept relative module paths, filtered modules.dep, filtered modules.alias)."""
    dep_lines, keep = [], set()
    with open(os.path.join(moddir, "modules.dep")) as f:
        deps = [line.rstrip("\n") for line in f if line.strip()]
    wanted = {}
    for line in deps:
        mod, rest = line.split(":", 1)
        wanted[mod] = rest.split()
    def closure(m, seen=None):
        seen = set() if seen is None else seen
        for d in wanted.get(m, []):
            if d not in seen:
                seen.add(d)
                closure(d, seen)
        return seen

    # Keep a module only if neither it nor anything it needs is excluded.
    selected = {
        m for m in wanted
        if m.startswith(MODULE_PREFIXES) and not EXCLUDE.search(m)
        and not any(EXCLUDE.search(d) for d in closure(m))
    }
    # Close over dependencies so every kept module can actually load.
    stack = list(selected)
    while stack:
        m = stack.pop()
        for d in wanted.get(m, []):
            if d not in selected:
                selected.add(d)
                stack.append(d)
    for line in deps:
        mod = line.split(":", 1)[0]
        if mod in selected:
            dep_lines.append(line)
            keep.add(mod)
    names = {os.path.basename(m)[:-3].replace("-", "_") for m in keep}
    alias_lines = []
    with open(os.path.join(moddir, "modules.alias")) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3 and parts[0] == "alias" and parts[2].replace("-", "_") in names:
                alias_lines.append(line)
    return keep, "\n".join(dep_lines) + "\n", "".join(alias_lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", required=True, help="os/build directory")
    ap.add_argument("--out", required=True)
    ap.add_argument("--modroot", help="module installation root (default: BUILD/modroot)")
    args = ap.parse_args()
    b = os.path.abspath(args.build)

    gen = os.path.join(b, "kernel/usr/gen_init_cpio")
    kver = open(os.path.join(b, "kernel/include/config/kernel.release")).read().strip()
    moddir = os.path.join(args.modroot or os.path.join(b, "modroot"), "lib/modules", kver)

    entries, dirs = [], set()

    def add_dir(path):
        parts = path.strip("/").split("/")
        for i in range(1, len(parts) + 1):
            d = "/" + "/".join(parts[:i])
            if d not in dirs:
                dirs.add(d)
                entries.append(f"dir {d} 0755 0 0")

    def add_tree(src, dst):
        for path in walk(src):
            rel = os.path.relpath(path, src)
            target = os.path.join(dst, rel)
            add_dir(os.path.dirname(target))
            if os.path.islink(path):
                entries.append(f"slink {target} {os.readlink(path)} 0777 0 0")
            else:
                mode = "0755" if os.access(path, os.X_OK) else "0644"
                entries.append(f"file {target} {path} {mode} 0 0")

    for d in ["/dev", "/proc", "/sys", "/tmp", "/run", "/root", "/etc", "/boot", "/data", "/mnt"]:
        add_dir(d)
    entries.append("nod /dev/console 0600 0 0 c 5 1")
    entries.append("nod /dev/null 0666 0 0 c 1 3")
    entries.append(f"file /init {b}/substrate/ssi_init 0755 0 0")
    add_tree(os.path.join(b, "release"), "/ssi")
    add_tree(os.path.join(b, "runtime"), "/")

    keep, dep, alias = module_subset(moddir)
    for rel in sorted(keep):
        target = f"/lib/modules/{kver}/{rel}"
        add_dir(os.path.dirname(target))
        entries.append(f"file {target} {os.path.join(moddir, rel)} 0644 0 0")
    idx = os.path.join(b, "initramfs-index")
    os.makedirs(idx, exist_ok=True)
    for name, text in (("modules.dep", dep), ("modules.alias", alias)):
        with open(os.path.join(idx, name), "w") as f:
            f.write(text)
        entries.append(f"file /lib/modules/{kver}/{name} {os.path.join(idx, name)} 0644 0 0")
    for name in ("modules.builtin", "modules.order", "modules.builtin.modinfo"):
        p = os.path.join(moddir, name)
        if os.path.exists(p):
            entries.append(f"file /lib/modules/{kver}/{name} {p} 0644 0 0")

    manifest = os.path.join(b, "initramfs.list")
    with open(manifest, "w") as f:
        f.write("\n".join(entries) + "\n")

    cpio = subprocess.run([gen, manifest], check=True, stdout=subprocess.PIPE).stdout
    with open(args.out, "wb") as f:
        f.write(subprocess.run(["gzip", "-9n"], input=cpio, check=True, stdout=subprocess.PIPE).stdout)
    print(f"initramfs: {args.out} ({len(cpio) >> 20} MiB uncompressed, "
          f"{os.path.getsize(args.out) >> 20} MiB gzip, {len(keep)} modules)")


if __name__ == "__main__":
    sys.exit(main())
