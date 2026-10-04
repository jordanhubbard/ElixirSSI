#!/usr/bin/env python3
"""Register-level tests of the emulated RP1, without an operating system.

QEMU's raspi-cm5 machine runs under qtest with PCIe2 as the firmware leaves
it (pcie2-preinit): CPU 0x1f_0000_0000 reaches PCI 0, and PCI
0x10_0000_0000 reaches RAM. The test configures RP1 through the root
complex's EXT_CFG window as Linux's rp1 driver would, points MSI-X vectors
at RAM, and checks what the datasheet and Linux's drivers expect: identity
and BARs, MSIn_CFG (edge, level with IACK, the SET/CLR aliases, INTSTAT),
the atomic register aliases, GPIO through RIO and its interrupts, PLL lock,
and the Ethernet MAC's identity.

  python3 emulator/tests/test_rp1.py [-v]
"""
import os
import shutil
import socket
import subprocess
import tempfile
import unittest

OS = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
QEMU = os.environ.get("SSI_EMULATOR",
                      os.path.join(OS, "build", "emulator", "current", "build", "qemu-system-aarch64"))

PCIE2 = 0x10_0012_0000                  # PCIe2's registers
EXT_CFG_DATA = PCIE2 + 0x8000
EXT_CFG_INDEX = PCIE2 + 0x9000
PCI0 = 0x1f_0000_0000                   # CPU address of PCI address 0
RAM_FROM_PCI = 0x10_0000_0000           # PCI address of RAM address 0

BAR0, BAR1, BAR2 = 0x410000, 0x0, 0x400000   # where Linux puts them
MSIX_CAP = 0xb0
PERI = PCI0 + BAR1                      # RP1's peripheral window
PCIE_CFG = PERI + 0x108000
SET, CLR = 0x800, 0xc00                 # PCIE_CFG's aliases (Linux's rp1 driver)
XOR, ASET, ACLR = 0x1000, 0x2000, 0x3000  # the datasheet's atomic aliases
MSIX_ENABLE, MSIX_TEST, MSIX_IACK, MSIX_IACK_EN = 1, 2, 4, 8
MAILBOX = 0x10000                       # RAM the MSIs are written to


class QTest:
    def __init__(self):
        self.dir = tempfile.mkdtemp(prefix="rp1-qtest-")
        path = os.path.join(self.dir, "qtest.sock")
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(path)
        listener.listen(1)
        self.proc = subprocess.Popen(
            [QEMU, "-machine", "raspi-cm5,pcie2-preinit=on", "-accel", "qtest", "-qtest", f"unix:{path}",
             "-qtest-log", "/dev/null", "-display", "none", "-monitor", "none", "-serial", "none",
             "-nodefaults"],
            stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.dir, "qemu.log"), "wb"))
        listener.settimeout(30)
        self.sock, _ = listener.accept()
        listener.close()
        self.file = self.sock.makefile("rwb")

    def cmd(self, line):
        self.file.write(line.encode() + b"\n")
        self.file.flush()
        while True:
            reply = self.file.readline().decode().split()
            if not reply:
                raise EOFError(open(os.path.join(self.dir, "qemu.log")).read())
            if reply[0] == "OK":
                return reply[1:]
            if reply[0] == "IRQ":
                continue
            raise RuntimeError(f"{line}: {reply}")

    def readl(self, addr):
        return int(self.cmd(f"readl 0x{addr:x}")[0], 16)

    def writel(self, addr, value):
        self.cmd(f"writel 0x{addr:x} 0x{value:x}")

    def readw(self, addr):
        return int(self.cmd(f"readw 0x{addr:x}")[0], 16)

    def writew(self, addr, value):
        self.cmd(f"writew 0x{addr:x} 0x{value:x}")

    def close(self):
        self.sock.close()
        self.proc.kill()
        self.proc.wait()
        shutil.rmtree(self.dir, ignore_errors=True)


class RP1Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.path.exists(QEMU):
            raise unittest.SkipTest(f"no {QEMU}: run 'make emulator'")
        cls.q = QTest()
        cls.q.writel(EXT_CFG_INDEX, 1 << 20)   # bus 1, device 0, function 0

    @classmethod
    def tearDownClass(cls):
        cls.q.close()

    # RP1's configuration space, through the root complex
    def cfg_readl(self, off):
        return self.q.readl(EXT_CFG_DATA + off)

    def cfg_writel(self, off, value):
        self.q.writel(EXT_CFG_DATA + off, value)

    def setUp(self):
        q = self.q
        self.cfg_writel(0x10, BAR0)
        self.cfg_writel(0x14, BAR1)
        self.cfg_writel(0x18, BAR2)
        self.cfg_writel(0x04, 0x6)             # memory and bus master on
        # MSI-X on, every vector unmasked, each writing its number to RAM
        q.writew(EXT_CFG_DATA + MSIX_CAP + 2, 0x8000)
        for n in range(64):
            entry = PCI0 + BAR0 + 16 * n
            q.writel(entry, (RAM_FROM_PCI + MAILBOX) & 0xffffffff)
            q.writel(entry + 4, (RAM_FROM_PCI + MAILBOX) >> 32)
            q.writel(entry + 8, 0x1000 + n)
            q.writel(entry + 12, 0)
        self.clear_mailbox()

    def clear_mailbox(self):
        self.q.writel(MAILBOX, 0)

    def mailbox(self):
        return self.q.readl(MAILBOX)

    def msix_cfg(self, n):
        return PCIE_CFG + 0x8 + 4 * n

    def test_identity(self):
        self.assertEqual(self.cfg_readl(0x00), 0x00011de4)       # 1de4:0001
        self.assertEqual(self.cfg_readl(0x08), 0x02000002)       # Ethernet, rev 2 (C0)
        self.assertEqual(self.cfg_readl(0x2c), 0)                # no subsystem
        self.assertEqual(self.q.readl(PERI + 0x0), 0x20001927)   # SYSINFO.CHIP_ID
        self.assertEqual(self.q.readl(PERI + 0x4), 0x2)          # PLATFORM: ASIC

    def test_bar_sizes(self):
        sizes = []
        for off in (0x10, 0x14, 0x18):
            self.cfg_writel(off, 0xffffffff)
            sizes.append(self.cfg_readl(off))
        self.setUp()
        # 16 KiB, 4 MiB, 64 KiB, all 32-bit non-prefetchable memory
        self.assertEqual(sizes, [0xffffc000, 0xffc00000, 0xffff0000])

    def test_edge_vector_fires_on_each_rising_edge(self):
        q, cfg = self.q, self.msix_cfg(5)
        q.writel(cfg, MSIX_ENABLE)
        q.writel(cfg + SET, MSIX_TEST)
        self.assertEqual(self.mailbox(), 0x1005)
        self.clear_mailbox()
        q.writel(cfg + CLR, MSIX_TEST)
        self.assertEqual(self.mailbox(), 0)
        q.writel(cfg + SET, MSIX_TEST)
        self.assertEqual(self.mailbox(), 0x1005)
        q.writel(cfg, 0)

    def test_level_vector_waits_for_iack(self):
        q, cfg = self.q, self.msix_cfg(6)
        q.writel(cfg, MSIX_ENABLE | MSIX_IACK_EN)
        q.writel(cfg + SET, MSIX_TEST)
        self.assertEqual(self.mailbox(), 0x1006)
        self.clear_mailbox()
        # Another edge before the acknowledgement sends nothing
        q.writel(cfg + CLR, MSIX_TEST)
        q.writel(cfg + SET, MSIX_TEST)
        self.assertEqual(self.mailbox(), 0)
        # IACK with the source still asserted sends the vector again
        q.writel(cfg + SET, MSIX_IACK)
        self.assertEqual(self.mailbox(), 0x1006)
        self.clear_mailbox()
        # IACK with the source quiet sends nothing, and re-arms the edge
        q.writel(cfg + CLR, MSIX_TEST)
        q.writel(cfg + SET, MSIX_IACK)
        self.assertEqual(self.mailbox(), 0)
        q.writel(cfg + SET, MSIX_TEST)
        self.assertEqual(self.mailbox(), 0x1006)
        q.writel(cfg, 0)
        self.assertEqual(q.readl(cfg) & 0xf, 0)

    def test_set_and_clear_aliases(self):
        q, cfg = self.q, self.msix_cfg(60)
        q.writel(cfg, 0)
        q.writel(cfg + SET, MSIX_IACK_EN)
        self.assertEqual(q.readl(cfg), MSIX_IACK_EN)
        q.writel(cfg + SET, MSIX_ENABLE)
        self.assertEqual(q.readl(cfg), MSIX_IACK_EN | MSIX_ENABLE)
        q.writel(cfg + CLR, MSIX_IACK_EN)
        self.assertEqual(q.readl(cfg), MSIX_ENABLE)
        q.writel(cfg, 0)

    def test_gpio_rio_loopback_and_interrupt(self):
        q = self.q
        ctrl = PERI + 0xd0000 + 8 * 5 + 4               # GPIO5_CTRL
        status = PERI + 0xd0000 + 8 * 5                 # GPIO5_STATUS
        rio = PERI + 0xe0000                            # SYS_RIO0
        q.writel(ctrl, 5)                               # FUNCSEL sys_rio
        q.writel(rio + 0x4 + ASET, 1 << 5)              # OE
        q.writel(rio + 0x0 + ASET, 1 << 5)              # OUT high
        self.assertTrue(q.readl(rio + 0x8) & (1 << 5))  # IN reads it back
        st = q.readl(status)
        self.assertTrue(st & (1 << 9) and st & (1 << 13) and st & (1 << 17))
        # A rising edge, enabled and routed to PCIe, raises IO_BANK0
        q.writel(ctrl + XOR, 1 << 28)                   # IRQRESET: forget old edges
        q.writel(rio + 0x0 + ACLR, 1 << 5)
        q.writel(ctrl + ASET, 1 << 21)                  # IRQEN_EDGE_HIGH
        q.writel(PERI + 0xd0000 + 0x11c, 1 << 5)        # PCIE_INTE
        q.writel(self.msix_cfg(0), MSIX_ENABLE | MSIX_IACK_EN)
        self.clear_mailbox()
        q.writel(rio + 0x0 + ASET, 1 << 5)
        self.assertEqual(q.readl(PERI + 0xd0000 + 0x124), 1 << 5)   # PCIE_INTS
        self.assertTrue(q.readl(PCIE_CFG + 0x108) & 1)              # INTSTATL
        self.assertEqual(self.mailbox(), 0x1000)
        # IRQRESET clears the latched edge, and the line falls
        q.writel(ctrl + ASET, 1 << 28)
        self.assertEqual(q.readl(PERI + 0xd0000 + 0x124), 0)
        self.assertFalse(q.readl(PCIE_CFG + 0x108) & 1)
        q.writel(self.msix_cfg(0), 0)
        q.writel(PERI + 0xd0000 + 0x11c, 0)

    def test_pll_locks_when_powered(self):
        q, pll = self.q, PERI + 0x28000                 # PLL_VIDEO
        q.writel(pll + 0x4, 0x3f)                       # powered down
        self.assertFalse(q.readl(pll) & (1 << 31))
        q.writel(pll + 0x4, 0x4)                        # on (DSMPD only)
        self.assertTrue(q.readl(pll) & (1 << 31))

    def test_atomic_aliases(self):
        q, reg = self.q, PERI + 0x18000 + 0x64          # CLK_ETH_CTRL
        q.writel(reg, 0x800)
        q.writel(reg + XOR, 0x801)
        self.assertEqual(q.readl(reg), 0x001)
        q.writel(reg + ASET, 0x30)
        self.assertEqual(q.readl(reg), 0x031)
        q.writel(reg + ACLR, 0x11)
        self.assertEqual(q.readl(reg), 0x020)
        self.assertEqual(q.readl(reg + XOR), 0x020)     # reads have no side effects

    def test_ethernet_mac_identity(self):
        self.assertEqual(self.q.readl(PERI + 0x100000 + 0xfc), 0x00020118)   # GEM MID

    def test_unmodelled_blocks_read_zero(self):
        self.assertEqual(self.q.readl(PERI + 0x50000), 0)   # spi0
        self.assertEqual(self.q.readl(PERI + 0xc8000), 0)   # adc


if __name__ == "__main__":
    unittest.main()
