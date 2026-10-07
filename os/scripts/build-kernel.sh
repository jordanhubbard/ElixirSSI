#!/bin/sh
# Runs inside the kernel builder. /kernel is a Linux volume, /os is the checkout.
set -eu
src=/kernel/src
out=/kernel/out
export_dir=/os/build/kernel
if [ ! -f "$src/Makefile" ]; then
    git clone --depth 1 -b "${LINUX_BRANCH:?}" "${LINUX_URL:?}" "$src"
fi
mkdir -p "$out"
make -C "$src" O="$out" ARCH=arm64 bcm2712_defconfig
cd "$src"
scripts/kconfig/merge_config.sh -m -O "$out" "$out/.config" /os/kernel/elixirssi.config
make O="$out" ARCH=arm64 olddefconfig
make O="$out" ARCH=arm64 -j"${SSI_KERNEL_JOBS:-$(nproc)}" Image modules dtbs

# Export everything image assembly consumes. Publish Image last, so a failed
# build/export cannot leave a seemingly current Make target behind.
rm -rf /kernel/modroot
make O="$out" ARCH=arm64 INSTALL_MOD_PATH=/kernel/modroot INSTALL_MOD_STRIP=1 modules_install
# Module names such as xt_RATEEST.ko and xt_rateest.ko also require a
# case-sensitive filesystem. Transport them as an archive, never loose files
# on the macOS mount. Export only the indexes needed by verify_cm5.py there.
tar -C /kernel/modroot -cf /os/build/modules.tar lib
kver=$(cat "$out/include/config/kernel.release")
rm -rf /os/build/modroot
mkdir -p "/os/build/modroot/lib/modules/$kver"
cp /kernel/modroot/lib/modules/"$kver"/modules.* "/os/build/modroot/lib/modules/$kver/"
mkdir -p "$export_dir/arch/arm64/boot/dts" "$export_dir/usr" "$export_dir/include/config"
cp -a "$out/arch/arm64/boot/dts/." "$export_dir/arch/arm64/boot/dts/"
cp "$out/.config" "$export_dir/.config"
cp "$out/vmlinux" "$export_dir/vmlinux"
cp "$out/usr/gen_init_cpio" "$export_dir/usr/"
cp "$out/include/config/kernel.release" "$export_dir/include/config/"
cp "$out/arch/arm64/boot/Image" "$export_dir/arch/arm64/boot/Image.tmp"
chown -R "$SSI_UID:$SSI_GID" "$export_dir" /os/build/modroot /os/build/modules.tar
mv "$export_dir/arch/arm64/boot/Image.tmp" "$export_dir/arch/arm64/boot/Image"
