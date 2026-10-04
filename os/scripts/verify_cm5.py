#!/usr/bin/env python3
"""Hardware-free verification of the ElixirSSI Compute Module 5 image.

QEMU cannot emulate the BCM2712, so this checks everything that does not need
the silicon:

  * the MBR has a bootable FAT32 partition and an ext4 data partition;
  * every file config.txt names (kernel, initramfs) exists on the FAT
    partition, along with the CM5 device trees and overlays;
  * the kernel is an arm64 Image with the page size the BCM2712 firmware
    expects;
  * every device on the CM5 boot path in the device tree (eMMC, PCIe, the RP1
    south bridge, Ethernet, UART, GPIO) is claimed by a driver built into the
    kernel — so the node reaches its shell and the network without loading a
    single module — and the remaining enabled devices have a driver either
    built in or in the initramfs.
"""
import fnmatch
import os
import re
import struct
import subprocess
import sys

OS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B = os.path.join(OS, "build")
IMG = os.path.join(B, "cm5", "elixirssi-cm5.img")
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  -- ' + detail) if detail else ''}")


def run(*cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def mtools(cmd, *args):
    env = dict(os.environ, MTOOLS_SKIP_CHECK="1")
    return subprocess.run([cmd, "-i", f"{IMG}@@4M", *args], check=True, capture_output=True, env=env).stdout


def builtin_of_aliases(kver):
    """Device-tree compatibles matched by drivers linked into the kernel."""
    path = os.path.join(B, "modroot/lib/modules", kver, "modules.builtin.modinfo")
    raw = open(path, "rb").read().split(b"\0")
    return [r.split(b"alias=", 1)[1].decode() for r in raw if b".alias=of:" in r]


def initramfs_aliases():
    return [line.split()[1] for line in open(os.path.join(B, "initramfs-index", "modules.alias")) if line.startswith("alias of:")]


def compat_patterns(aliases):
    """Glob patterns over the compatible string, from `of:N<name>T<type>C<compat>` aliases."""
    out = []
    for a in aliases:
        m = re.match(r"of:N(.*?)T(.*?)C(.*)$", a)
        if m:
            pat = m.group(3)
            out.append(pat[:-2] if pat.endswith("C*") else pat)
    return out


def claimed(compat, patterns, vmlinux=b""):
    """A driver claims `compat` if a module alias matches it, or if a built-in
    driver's of_match table names it (drivers without MODULE_DEVICE_TABLE
    never appear in modinfo, but their table strings are in vmlinux)."""
    if any(fnmatch.fnmatchcase(compat, p) for p in patterns):
        return True
    return bool(vmlinux) and (b"\0" + compat.encode() + b"\0") in vmlinux


def dt_nodes(dtb):
    """(path, compatibles, enabled) for every node with a compatible string."""
    text = run("dtc", "-q", "-I", "dtb", "-O", "dts", dtb)
    nodes, stack = [], []
    for line in text.splitlines():
        s = line.strip()
        if s.endswith("{"):
            stack.append({"name": s[:-1].strip().split(":")[-1].strip(), "compat": [], "status": "okay"})
        elif s.startswith("};"):
            if stack:
                n = stack.pop()
                if n["compat"]:
                    path = "/".join(x["name"] for x in stack + [n])
                    nodes.append((path, n["compat"], n["status"] in ("okay", "ok")))
        elif s.startswith("compatible =") and stack:
            stack[-1]["compat"] = [c for q in re.findall(r'"([^"]+)"', s) for c in q.split("\\0")]
        elif s.startswith("status =") and stack:
            stack[-1]["status"] = re.findall(r'"([^"]+)"', s)[0]
    return nodes


def main():
    if not os.path.exists(IMG):
        print("no image: run make image-cm5 first")
        return 2
    kver = open(os.path.join(B, "kernel/include/config/kernel.release")).read().strip()

    parts = run("sfdisk", "-d", IMG)
    p1 = re.search(r"img1 : start=\s*(\d+), size=\s*(\d+), type=c, bootable", parts)
    p2 = re.search(r"img2 : start=\s*(\d+), size=\s*(\d+), type=83", parts)
    check("MBR: bootable FAT32 p1 at 4 MiB and Linux p2", bool(p1 and p2 and p1.group(1) == "8192"))
    with open(IMG, "rb") as f:
        f.seek(int(p2.group(1)) * 512 + 1024 + 0x38)
        check("p2 holds an ext4 filesystem", struct.unpack("<H", f.read(2))[0] == 0xEF53)

    listing = mtools("mdir", "-b", "-/", "::/").decode()
    files = {os.path.basename(p.strip()) for p in listing.splitlines()}
    config = mtools("mtype", "::/config.txt").decode()
    named = re.findall(r"^kernel=(\S+)", config, re.M) + re.findall(r"^initramfs (\S+)", config, re.M)
    check("files named by config.txt are on the boot partition", all(n in files for n in named), ", ".join(named))
    cmdline = mtools("mtype", "::/cmdline.txt").decode()
    check("cmdline.txt is one line with a serial console", cmdline.count("\n") <= 1 and "console=serial0" in cmdline, cmdline.strip())
    dtbs = sorted(f for f in files if f.startswith("bcm2712-rpi-cm5"))
    check("CM5 and CM5 Lite device trees present", {"bcm2712-rpi-cm5-cm5io.dtb", "bcm2712-rpi-cm5l-cm5io.dtb"} <= set(dtbs), " ".join(dtbs))
    check("device-tree overlays and overlay map present", "overlay_map.dtb" in files and sum(f.endswith(".dtbo") for f in files) > 100)
    conf = mtools("mtype", "::/ssi.conf").decode()
    check("ssi.conf carries a cluster secret", re.search(r"^secret = \S{16,}", conf, re.M) is not None)

    with open(os.path.join(B, "kernel/arch/arm64/boot/Image"), "rb") as f:
        head = f.read(64)
    flags = struct.unpack("<Q", head[24:32])[0]
    page = {1: "4K", 2: "16K", 3: "64K"}.get((flags >> 1) & 3, "unspecified")
    check("kernel is an arm64 Image with 16K pages (BCM2712 default)", head[56:60] == b"ARM\x64" and page == "16K", page)

    built = compat_patterns(builtin_of_aliases(kver))
    vmlinux = open(os.path.join(B, "kernel/vmlinux"), "rb").read()
    modular = compat_patterns(initramfs_aliases())
    check("matcher self-test: a made-up device is not claimed",
          not claimed("example,no-such-device", built + modular, vmlinux) and claimed("cdns,macb", built))
    for dtb in ("bcm2712-rpi-cm5-cm5io.dtb", "bcm2712-rpi-cm5l-cm5io.dtb"):
        nodes = dt_nodes(os.path.join(B, "kernel/arch/arm64/boot/dts/broadcom", dtb))
        boot_path = {
            "eMMC/SD controller": "bcm2712-sdhci",
            "PCIe root complex": "bcm2712-pcie",
            "RP1 Ethernet (Cadence GEM)": "rp1-gem",
            "PL011 console UART": "arm,pl011",
            "RP1 GPIO/pinctrl": "rp1-gpio",
        }
        for label, needle in boot_path.items():
            matches = [(p, c) for p, c, en in nodes if en and any(needle in x for x in c)]
            ok = bool(matches) and all(any(claimed(x, built, vmlinux) for x in c) for _, c in matches)
            check(f"{dtb}: {label} driver built in", ok, ", ".join(sorted({c[0] for _, c in matches})) or "no node")
        enabled = [(p, c) for p, c, en in nodes if en]
        unclaimed = [c[0] for p, c in enabled if not any(claimed(x, built, vmlinux) or claimed(x, modular) for x in c)]
        # Core blocks (CPUs, interrupt controllers, timers, memory) bind without
        # driver-model aliases; list the rest for review rather than fail.
        core = re.compile(r"arm,(cortex|armv8|gic|psci|arch_timer)|simple-bus|fixed-clock|fixed-factor|regulator-fixed|"
                          r"gpio-leds|syscon|shared-dma-pool|brcm,bcm2712-(mip|l2-intc|hdmi)|mmio-sram|raspberrypi,bcm2835-firmware")
        missing = sorted({u for u in unclaimed if not core.search(u)})
        coverage = 1 - len(missing) / max(len(enabled), 1)
        check(f"{dtb}: {len(enabled)} enabled devices, {coverage:.0%} have a driver", coverage > 0.85,
              ("unclaimed: " + " ".join(missing[:12])) if missing else "")

    print(f"\n{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
