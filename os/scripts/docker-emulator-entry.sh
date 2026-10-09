#!/bin/sh
# Container-only entry point. Never silently write Linux state on the host bind.
set -eu
for path in "${SSI_EMULATOR_DIR:?}" "${SSI_CM5_STATE_DIR:-}"; do
    [ -n "$path" ] || continue
    if ! mountpoint -q "$path"; then
        echo "CM5 Docker volume is not mounted at $path" >&2
        exit 1
    fi
done
if [ -n "${SSI_CM5_STATE_DIR:-}" ]; then
    # The fixed container name excludes another active owner of these files.
    for dir in "$SSI_CM5_STATE_DIR" "$SSI_CM5_STATE_DIR/tests"; do
        rm -f "$dir"/node*.pid "$dir"/node*.sock "$dir"/node*.mon
    done
fi
exec "$@"
