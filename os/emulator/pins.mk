# The emulator's pinned inputs. build-qemu.sh reads this file as shell too.
#
# rpi5_machine: an out-of-tree QEMU model of the Raspberry Pi 5's BCM2712
# (GPL-2.0-or-later), which ElixirSSI adopts as its base and extends with
# RP1 and the Compute Module 5 (see docs/architecture/cm5-emulation.md).
RPI5_MACHINE_URL=https://github.com/hatter6822/rpi5_machine
RPI5_MACHINE_REV=3548a769a18cd928eb1d3ecee73a7a96ce92d620
# The QEMU commit rpi5_machine pins as its submodule (v11.1.1)
QEMU_REV=c3d48b7d1e89604920e5b81b91140c2ad39a1943
