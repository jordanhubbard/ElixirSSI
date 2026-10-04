#!/usr/bin/env bash
# Build the CM5 emulator: QEMU with rpi5_machine's BCM2712 model, pinned,
# plus this directory's RP1 model and Compute Module 5 board.
#
#   base-patches/   changes to rpi5_machine's own files (board, boot script)
#   qemu/overlay/   new files, laid out as in the QEMU tree
#   qemu/patches/   changes to QEMU files, on top of rpi5_machine's series
#
# A source tree is prepared once per set of inputs (pins, patches, overlay
# and this script), in a temporary directory that is renamed into place
# only when every step has succeeded; build/emulator/current then points
# at it. The system QEMU is never touched.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
OUT=${SSI_EMULATOR_DIR:-$HERE/../build/emulator}
JOBS=${JOBS:-$(nproc)}
# shellcheck source=pins.mk
. "$HERE/pins.mk"

die() { printf 'build-qemu: %s\n' "$*" >&2; exit 1; }
for tool in git patch ninja python3 cc; do
    command -v "$tool" >/dev/null || die "$tool is required"
done
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

exec 9>"$OUT/.lock"
flock 9

inputs_key() {
    (
        cd "$HERE"
        printf '%s\n' "$RPI5_MACHINE_URL" "$RPI5_MACHINE_REV" "$QEMU_REV"
        find build-qemu.sh base-patches qemu -type f | LC_ALL=C sort |
            xargs sha256sum
    ) | sha256sum | cut -c1-16
}

# A pristine checkout of the pinned base and its QEMU submodule, fetched
# once and copied for every preparation.
fetch_base() {
    local cache=$OUT/cache/rpi5_machine-$RPI5_MACHINE_REV
    if [ ! -e "$cache/.fetched" ]; then
        rm -rf "$cache.partial"
        git init -q "$cache.partial"
        git -C "$cache.partial" fetch -q --depth 1 "$RPI5_MACHINE_URL" \
            "$RPI5_MACHINE_REV"
        git -C "$cache.partial" checkout -q FETCH_HEAD
        git -C "$cache.partial" submodule update -q --init --depth 1 qemu
        [ "$(git -C "$cache.partial/qemu" rev-parse HEAD)" = "$QEMU_REV" ] ||
            die "rpi5_machine $RPI5_MACHINE_REV does not pin QEMU $QEMU_REV"
        touch "$cache.partial/.fetched"
        rm -rf "$cache"
        mv "$cache.partial" "$cache"
    fi
    printf '%s\n' "$cache"
}

prepare() {
    local key=$1 src=$OUT/src-$1 cache tmp p
    [ -e "$src/.prepared" ] && return 0
    cache=$(fetch_base)
    tmp=$(mktemp -d "$OUT/.prepare-$key.XXXXXX")
    cp -a "$cache" "$tmp/tree"
    for p in "$HERE"/base-patches/*.patch; do
        [ -e "$p" ] || continue
        patch -s --batch --forward -p1 -d "$tmp/tree" -i "$p" ||
            die "base patch $(basename "$p") does not apply"
    done
    (cd "$tmp/tree" && scripts/qemu-tree apply >/dev/null)
    (cd "$HERE/qemu/overlay" && find . -type f) | while read -r f; do
        mkdir -p "$(dirname "$tmp/tree/qemu/$f")"
        cp "$HERE/qemu/overlay/$f" "$tmp/tree/qemu/$f"
    done
    for p in "$HERE"/qemu/patches/*.patch; do
        [ -e "$p" ] || continue
        patch -s --batch --forward -p1 -d "$tmp/tree/qemu" -i "$p" ||
            die "QEMU patch $(basename "$p") does not apply"
    done
    touch "$tmp/tree/.prepared"
    rm -rf "$src"
    mv "$tmp/tree" "$src"
    rmdir "$tmp"
}

key=$(inputs_key)
prepare "$key"
src=$OUT/src-$key
mkdir -p "$src/build"
if [ ! -e "$src/build/build.ninja" ]; then
    (cd "$src/build" && ../qemu/configure --target-list=aarch64-softmmu \
        --disable-docs --disable-user --enable-slirp --enable-fdt=system \
        >configure.log 2>&1) || die "configure failed: $src/build/configure.log"
fi
ninja -C "$src/build" -j"$JOBS" qemu-system-aarch64 >"$src/build/ninja.log" 2>&1 ||
    die "build failed: $src/build/ninja.log"
"$src/build/qemu-system-aarch64" -M help | grep -q '^raspi-cm5 ' ||
    die "the built QEMU has no raspi-cm5 machine"
ln -sfn "src-$key" "$OUT/current"
# Trees of earlier inputs are only taking space once this one works
for old in "$OUT"/src-*; do
    [ "$old" = "$src" ] || rm -rf "$old"
done
printf '%s\n' "$OUT/current/build/qemu-system-aarch64"
