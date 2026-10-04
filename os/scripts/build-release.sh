#!/bin/sh
# Runs inside the ElixirSSI builder image (os/mixdocker.sh). Produces:
#   build/substrate/ssi_init      static PID-1 shim
#   build/release/                the Elixir release (ERTS, OTP, Elixir, SSI)
#   build/runtime/                shared libraries and terminfo the runtime needs
set -eu
cd /os
erts_inc=$(ls -d /opt/erlang/lib/erlang/erts-*/include)

mkdir -p ssi/priv build/substrate
gcc -O2 -Wall -Wextra -Wno-unused-parameter -fPIC -shared -I"$erts_inc" \
    -o ssi/priv/ssi_sys_nif.so substrate/ssi_sys_nif.c
gcc -Os -Wall -static -o build/substrate/ssi_init substrate/ssi_init.c
strip build/substrate/ssi_init

cd ssi
MIX_ENV=prod mix release --overwrite --path /os/build/release --quiet
cd /os

# A running system needs only the emulator, its launcher and helpers; strip
# debug symbols and drop build-time tools (compilers, epmd, erl_call...).
erts=$(ls -d build/release/erts-*)
for f in "$erts"/bin/*; do
  case "$(basename "$f")" in
    beam.smp|erlexec|erl_child_setup|inet_gethost) ;;
    *) rm -f "$f" ;;
  esac
done
find build/release -type f \( -name '*.so' -o -name beam.smp -o -name erlexec -o -name erl_child_setup -o -name inet_gethost \) \
  -exec strip --strip-unneeded {} \;
rm -rf build/release/bin build/release/erts-*/doc build/release/erts-*/man build/release/erts-*/src build/release/erts-*/include

# Every shared library any executable or NIF in the release links against.
rm -rf build/runtime && mkdir -p build/runtime/lib build/runtime/usr/lib build/runtime/usr/share/terminfo
find build/release -type f \( -name '*.so' -o -perm -u+x \) -exec sh -c 'file "$1" | grep -q ELF' _ {} \; -print \
  | while read -r f; do ldd "$f" 2>/dev/null || true; done \
  | awk '/=>/ { print $3 } /ld-musl/ { print $1 }' | sort -u | while read -r lib; do
      [ -f "$lib" ] || continue
      case "$lib" in
        /lib/*) cp -L "$lib" build/runtime/lib/ ;;
        *)      cp -L "$lib" build/runtime/usr/lib/ ;;
      esac
    done
# musl's loader doubles as libc.
[ -e build/runtime/lib/ld-musl-aarch64.so.1 ] || cp -L /lib/ld-musl-aarch64.so.1 build/runtime/lib/
ln -sf ld-musl-aarch64.so.1 build/runtime/lib/libc.musl-aarch64.so.1

# Terminal descriptions for serial consoles and SSH clients.
for t in v/vt100 v/vt102 v/vt220 l/linux x/xterm x/xterm-256color d/dumb s/screen; do
  if [ -f /usr/share/terminfo/$t ]; then
    mkdir -p build/runtime/usr/share/terminfo/$(dirname $t)
    cp -L /usr/share/terminfo/$t build/runtime/usr/share/terminfo/$t
  fi
done
echo "release: $(du -sh build/release | cut -f1), runtime libs: $(ls build/runtime/lib build/runtime/usr/lib | grep -c so)"
