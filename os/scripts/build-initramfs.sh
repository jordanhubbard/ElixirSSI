#!/bin/sh
# Runs in the runtime builder: Linux module filenames can differ only by case.
set -eu
cd /os
modroot=$(mktemp -d)
trap 'rm -rf "$modroot"' EXIT
tar -xf build/modules.tar -C "$modroot"
python3 scripts/mkinitramfs.py --build build --out build/ssi-initramfs.cpio.gz --modroot "$modroot"
