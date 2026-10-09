#!/bin/sh
# Platform bootstrap only. Phoenix/OTP owns cluster and workspace operations.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
key=$(printf '%s' "$root" | cksum | awk '{print $1}')
name="elixirssi-command-$key"
port=${SSI_COMMAND_PORT:-4000}
desktop_port=${SSI_DESKTOP_PORT:-4010}
case "$port" in ''|*[!0-9]*) echo 'SSI_COMMAND_PORT must be a port number' >&2; exit 1;; esac
case "$desktop_port" in ''|*[!0-9]*) echo 'SSI_DESKTOP_PORT must be a port number' >&2; exit 1;; esac
image=$(cat "$root/command-image")
docker info >/dev/null || { echo 'Start Docker Desktop, then open ElixirSSI again.' >&2; exit 1; }
mkdir -p "$root/state/command"
if [ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null || true)" != true ]; then
  docker run -d --rm --init --name "$name" --platform linux/arm64 \
    -p "127.0.0.1:$port:$port" -p "127.0.0.1:$desktop_port:$desktop_port" --add-host host.docker.internal:host-gateway \
    -e "PORT=$port" -e SSI_COMMAND_BIND=all \
    -e "SSI_DESKTOP_PORT=$desktop_port" \
    -e SSI_INSTALLATION=/installation -e "SSI_INSTALLATION_HOST=$root" \
    -e SSI_COMMAND_DATA=/data -e "SSI_COMMAND_DATA_HOST=$root/state/command" \
    -e SSI_GUEST_HOST=host.docker.internal \
    -v "$root:/installation:ro" -v "$root/state/command:/data" \
    -v /var/run/docker.sock:/var/run/docker.sock "$image" >/dev/null
fi
attempt=0
until ticket=$(docker exec "$name" /command/bin/ssi_command rpc 'IO.write(ElixirSSI.Command.Auth.ticket())' 2>/dev/null); do
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 30 ]; then
    echo 'Command node did not start. Its logs follow:' >&2
    docker logs --tail 30 "$name"
    exit 1
  fi
  sleep 1
done
url="http://localhost:$port/login#ticket=$ticket"
if [ "${SSI_NO_OPEN:-0}" != 1 ]; then
case "$(uname -s)" in
  Darwin) open "$url" ;;
  Linux) if command -v wslview >/dev/null 2>&1; then wslview "$url"; else xdg-open "$url"; fi ;;
  *) echo 'Open the command-node address in your browser.' >&2; exit 1 ;;
esac
fi
echo "ElixirSSI workspace is running at http://localhost:$port"
