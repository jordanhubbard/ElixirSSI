#!/bin/sh
# Host-side wrapper. Each checkout gets a persistent, case-sensitive Linux volume.
set -eu
cd "$(dirname "$0")/.."
here=$(pwd -P)
key=$(printf '%s' "$here" | cksum | awk '{print $1}')
volume="elixirssi-kernel-$key"
image="elixirssi-kernel:alpine${ALPINE_VERSION:?}"
docker build --platform linux/arm64 --build-arg "ALPINE_VERSION=$ALPINE_VERSION" \
    -f toolchain/kernel.Dockerfile -t "$image" toolchain
echo "Kernel cache: Docker volume $volume"
exec docker run --rm --platform linux/arm64 \
    -e LINUX_URL -e LINUX_BRANCH -e SSI_KERNEL_JOBS \
    -e "SSI_UID=$(id -u)" -e "SSI_GID=$(id -g)" \
    -v "$here:/os" -v "$volume:/kernel" "$image" sh -c \
    'cp scripts/build-kernel.sh /tmp/build-kernel.sh; exec sh /tmp/build-kernel.sh'
