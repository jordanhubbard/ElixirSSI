#!/usr/bin/env bash
# Linux-hosted CM5 emulator, with case-sensitive sources and persistent cards.
set -euo pipefail
cd "$(dirname "$0")/.."
here=$(pwd -P)
key=$(printf '%s' "$here" | cksum | awk '{print $1}')
image=elixirssi-emulator:bookworm
# Keep named volumes outside the host bind: nested mounts can disappear behind
# Docker Desktop's host filesystem sharing layer.
mounts=(-v "$here:/os" -v "elixirssi-emulator-$key:/emulator"
    -e SSI_EMULATOR_DIR=/emulator
    -e SSI_EMULATOR=/emulator/current/build/qemu-system-aarch64)
if [ "${1:-}" = build ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        tools_key=$(sha256sum toolchain/emulator.Dockerfile | awk '{print $1}')
    else
        tools_key=$(shasum -a 256 toolchain/emulator.Dockerfile | awk '{print $1}')
    fi
    cached_key=$(docker image inspect --format '{{ index .Config.Labels "org.elixirssi.emulator-tools" }}' "$image" 2>/dev/null || true)
    if [ "$cached_key" != "$tools_key" ]; then
        docker build -f toolchain/emulator.Dockerfile \
            --label "org.elixirssi.emulator-tools=$tools_key" -t "$image" toolchain
    fi
    exec docker run --rm --init -e JOBS "${mounts[@]}" \
        "$image" sh scripts/docker-emulator-entry.sh bash emulator/build-qemu.sh
fi

# Keep all boards of a cluster in one container so their multicast switch and
# test sockets share a Linux network/filesystem. Publish management ports only
# on the host's loopback interface. Interactive use gets stdin and a terminal.
count=${N:-3}
case "$count" in ''|*[!0-9]*) echo 'N must be a positive integer' >&2; exit 2;; esac
[ "$count" -ge 1 ] && [ "$count" -le 64 ] || { echo 'N must be between 1 and 64' >&2; exit 2; }
tty=(-i)
if [ -t 0 ] && [ -t 1 ]; then tty=(-it); fi
args=(docker run --rm --init "${tty[@]}" --name "elixirssi-cm5-$key"
    -e SSI_FORWARD_BIND=0.0.0.0 -e SSI_CM5_MEM -e SSI_CM5_APPEND
    -e SSI_CM5_SWITCH -e SSI_CM5_QEMU_ARGS
    "${mounts[@]}" -v "elixirssi-cards-$key:/cards" -e SSI_CM5_STATE_DIR=/cards)
for ((i=1; i<=count; i++)); do
    args+=(-p "127.0.0.1:$((8180 + i)):$((8180 + i))"
        -p "127.0.0.1:$((8480 + i)):$((8480 + i))"
        -p "127.0.0.1:$((2320 + i)):$((2320 + i))")
done
exec "${args[@]}" "$image" sh scripts/docker-emulator-entry.sh "$@"
