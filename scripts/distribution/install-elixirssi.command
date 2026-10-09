#!/bin/sh
# Bootstrap the packaged Elixir installer. All installation policy is in OTP.
set -eu
assets=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
prefix=${1:-"$HOME/ElixirSSI"}
case "$(uname -sm)" in
  'Darwin arm64') platform=macos ;;
  'Linux aarch64') platform=linux ;;
  *) echo 'This package requires Apple Silicon macOS or ARM64 Linux with Docker.' >&2; exit 1 ;;
esac
if [ -e "$prefix" ]; then echo 'Choose a new installation directory to preserve existing data.' >&2; exit 1; fi
docker info >/dev/null
cd "$assets"
if command -v sha256sum >/dev/null 2>&1; then sha256sum -c SHA256SUMS; else shasum -a 256 -c SHA256SUMS; fi
docker load -i "$assets/elixirssi-command-linux-arm64.tar.gz"
mkdir -p "$(dirname -- "$prefix")"
parent=$(CDPATH= cd -- "$(dirname -- "$prefix")" && pwd -P)
name=$(basename -- "$prefix")
docker run --rm --platform linux/arm64 \
  -v "$assets:/assets:ro" -v "$parent:/install" -v /var/run/docker.sock:/var/run/docker.sock \
  -e "SSI_DESTINATION=/install/$name" -e "SSI_PLATFORM=$platform" \
  elixirssi-command:@VERSION@ /command/bin/ssi_command eval \
  'Application.ensure_all_started(:crypto); ElixirSSI.Command.Install.fresh!("/assets", System.fetch_env!("SSI_DESTINATION"), System.fetch_env!("SSI_PLATFORM"))'
exec "$parent/$name/elixirssi"
