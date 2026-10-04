#!/bin/sh
# Run a command inside the pinned ElixirSSI builder image with the os/ tree mounted.
set -e
here=$(cd "$(dirname "$0")" && pwd)
image=${SSI_BUILDER:-elixirssi-builder:otp29.1.1-ex1.20.4}
exec docker run --rm --platform linux/arm64 --network host -u "$(id -u):$(id -g)" -e HOME=/tmp -e MIX_HOME=/tmp/mix \
  -e MIX_ENV="${MIX_ENV:-dev}" -v "$here:/os" -w "/os/${SSI_WORKDIR:-ssi}" "$image" sh -c "$*"
