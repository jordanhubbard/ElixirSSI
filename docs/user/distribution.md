# Download and install ElixirSSI

[Project guide](../README.md) → distribution

GitHub releases provide a prebuilt system image and a workstation environment.
The same image targets Raspberry Pi 5, CM5 and CM5 Lite and runs on the CM5
emulator. Physical-board boot qualification is still pending; release evidence
identifies emulation and static board checks separately.

## Workstation installation

The first installer supports Apple Silicon macOS and ARM64 Linux with Docker
and Python 3.12 or newer. No OS or emulator compilation is required. Download
`install-elixirssi.py` from the release and run:

```console
python3 install-elixirssi.py --prefix "$HOME/ElixirSSI"
~/ElixirSSI/elixirssi start --nodes 3
```

The installer fetches the release's checksummed image, prebuilt emulator,
Elixir/OTP development container, source and desktop packages. For offline
installation, download the release assets into one folder and use
`--assets PATH --offline`. Installation refuses an existing destination, so an
upgrade cannot silently overwrite your cards. Keep old installations for their
persistent state.

`start --nodes N` boots N copies of the image on a private virtual switch and
opens the self-contained browser monitor with all endpoints configured. It
shows the aggregate SSI system, individual members, services and the timeline;
it remains available when the entire cluster is stopped. Pair controls from a
node shell as described in [getting started](getting-started.md). Management
ports bind to host loopback; HTTP is 8180+I, HTTPS 8480+I and SSH 2320+I.
The emulated console password is `elixir`; each installation has a separate
cluster secret. Virtual RAM defaults to 4096 MiB per node; choose N according
to host resources, or use `--memory MIB`.

```console
~/ElixirSSI/elixirssi status
~/ElixirSSI/elixirssi monitor
~/ElixirSSI/elixirssi stop
~/ElixirSSI/elixirssi start --nodes 3
~/ElixirSSI/elixirssi dev
~/ElixirSSI/elixirssi test
```

Stop/start preserves cards in an installation-specific Docker volume. `dev` opens the prebuilt Elixir/OTP environment at
`/os/ssi`; `elixirssi test` runs the installed source tests with a named BEAM node. The source tree also
contains the full Make build for deliberate system development.

## Graphical desktop

The installer includes the pinned RemoteOS-SDL executable for your host. It
needs the host's SDL2, SDL2_image, SDL2_ttf and FFmpeg runtime libraries. On
macOS install them with `brew install sdl2 sdl2_image sdl2_ttf ffmpeg`; on
ARM64 Debian/Ubuntu use the corresponding distribution runtime packages.

Start `~/ElixirSSI/elixirssi desktop` on a trusted network, then on Docker
Desktop use `start --nodes 3 --desktop host.docker.internal:17010`. On Linux,
provide a host address reachable from Docker. The SSI desktop includes the
cluster monitor, process view, distributed Mandelbrot renderer and Elixir
shell, and survives failure of the member drawing it. The RemoteOS transport
is for a trusted network or SSH tunnel.

## Physical Raspberry Pi 5 and CM5

Download `elixirssi-pi5-cm5.img.gz` and `SHA256SUMS` from the same release.
Verify its SHA-256, decompress it, and flash the resulting image to each
board's SD card (Pi 5 or CM5 Lite) or CM5 eMMC using your usual image writer.
Flashing replaces the target device's contents. Use one image on N boards.
The image includes Pi 5, CM5 and CM5 Lite device trees and selects the board
through firmware. Ethernet is required for cluster networking.

Before boot, edit `ssi.conf` on the FAT partition: give every board in your
cluster the same fresh `secret` and `cluster` name; configure SSH credentials
or copy `authorized_keys`. The downloadable image uses the explicitly warned
insecure default secret, never the release builder's private cluster secret.
Set `desktop = WORKSTATION-IP:17010` for RemoteOS. Connect Ethernet and power
on each board, then open any member's HTTP address or the downloaded
`monitor.html#endpoints=HOST1,HOST2,...`. Pair controls from the console or SSH.

## Release verification

The release skill requires every asset through `literate.release.json`.
`make release-assets` packages accepted products and emits an exact-commit
manifest. The release gate checks source/image currency; installer qualification
runs the packaged environment without compiling. Source archives accompany the
kernel and patched emulator. `SHA256SUMS` covers the public files; the release
publisher checks uploaded bytes against the qualified manifest.
