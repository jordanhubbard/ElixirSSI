# Getting started

[Project guide](../README.md) → getting started

## What is ElixirSSI?

ElixirSSI is a stand-alone operating system whose runtime is the Erlang BEAM
and whose system language is Elixir. It boots natively on Raspberry Pi
Compute Module 5 boards, and every CM5 running it on the same network joins
one **single system image**: one shell sees every machine's processes, one
filesystem tree spans their disks, computation spreads over all their cores,
and system services — including a remote graphical desktop — survive the loss
of any one machine. It is built for computer scientists who want a cluster
that behaves like one machine. See the [architecture](../architecture/elixirssi.md).

## Host prerequisites

- To build on macOS: Docker Desktop (running, with Linux containers), Apple's
  command-line tools (`make`, `git`, `python3`), and `curl`. `make` automatically builds the
  ARM64 kernel in Docker and assembles the initramfs there; no Homebrew Make or
  cross compiler is required. Apple Silicon runs the builder natively; Intel
  Macs need Docker's ARM64 emulation.
- To build and run on Linux: Docker, `make` (GNU Make 4 or newer), `git`,
  `python3`, `curl`, `mkfs.ext4`, and QEMU
  (`qemu-system-aarch64`). Debian/Ubuntu: `apt install qemu-system-arm
  e2fsprogs build-essential bc flex bison libssl-dev libelf-dev patch
  ninja-build pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev libfdt-dev
  python3-venv mtools` (including the full CM5 emulator's build dependencies).
- An arm64 host with `/dev/kvm` runs the VMs at native speed. On x86-64, also
  install `gcc-aarch64-linux-gnu` and `qemu-user-static` (binfmt for the arm64
  builder image); VMs then run emulated and several times slower.
- About 15 GB of disk for the kernel tree and builds.
- For the desktop: [RemoteOS-SDL](https://github.com/jordanhubbard/RemoteOS-SDL)
  built on the workstation that will show it.

## Build

```console
make build      # from the repository root; bare make does the same
make run        # build the CM5 emulator and boot the flashable image
make test       # unit/peer tests, build regressions, static image verification
make clean      # remove assembled outputs; preserve caches, cards and cluster secret
```

`make` fetches pinned, checksummed Erlang/OTP 29.1.1 and Elixir 1.20.4 sources
and the Raspberry Pi `rpi-6.18.y` kernel. Outputs land in `os/build/`:
`kernel/arch/arm64/boot/Image`, `ssi-initramfs.cpio.gz`, and the flashable
`cm5/elixirssi-cm5.img` with its compressed `.img.zst` copy. This is the same
image that `make run` boots and that you flash to CM5 eMMC or a CM5 Lite SD card.
Builds are incremental. Use `make image-cm5` to explicitly repack after changing
image settings such as `SSI_CLUSTER` or `SSI_AUTHORIZED_KEYS`.

On macOS, the kernel source and intermediate objects live in a persistent Docker
volume named `elixirssi-kernel-<checkout-id>` (printed during the build), keeping
them on a case-sensitive Linux filesystem. Finished kernel files and a
`modules.tar` archive are copied back into `os/build/`; module filenames can also
differ only by case, so they are unpacked only inside Docker. `make clean`
preserves this cache; removing the
named volume with `docker volume rm NAME` makes the next kernel rebuild download
and compile afresh. `make JOBS=6` limits kernel compiler concurrency; by default the container
uses its available CPUs. Linux can opt into this same path with
`make KERNEL_DOCKER=1`. `make test` and `make image-cm5` also use Docker.

On macOS, `run`, `cluster`, `emulator`, `test-emulator` and `test-cm5` use a
Linux emulator container. Emulator sources and cards live in per-checkout Docker
volumes (`elixirssi-emulator-*` and `elixirssi-cards-*`). The full CM5 model uses
CPU emulation; KVM acceleration applies only to the explicit Linux `virt` shortcut.
The advanced `test-monitor`, `test-cluster`, `test-desktop`, `run-virt` and
`cluster-virt` commands still require Linux host tools.

## Run the CM5 emulator

```console
make run                 # one full emulated CM5; serial console on your terminal
make cluster N=3         # three emulated CM5s; you get board 1's console
```

Quit QEMU with `Ctrl-A X`; exiting cluster mode also stops the other boards.
Node *I* forwards SSH to port `2320 + I`, HTTP to `8180 + I` and HTTPS to
`8480 + I` on localhost (SSH password `elixir` in development):

```console
ssh -p 2321 root@localhost
```

At the prompt (`ssi-550001(1)>`), the shell is Elixir with system commands:

```elixir
help                       # command summary
nodes                      # every machine: cores, memory, load, temperature
cluster                    # the aggregate machine
ps name: "SSI"             # processes on all machines, as HOST:<0.N.0>
write "/home/hello", "hi"  # visible at once from every node
cat "/proc/cluster"
pmap 1..1000, fn i -> {i, node()} end
mandel                     # ASCII Mandelbrot; each row computed somewhere else
bench                      # one core versus the whole cluster
SSI.Service.register(:counter, SSI.Demo.Counter)
SSI.Demo.Counter.inc()     # from any node; survives losing the one running it
```

Verify a whole cluster automatically (boots VMs, kills one, restarts it):

```console
make test-cm5
```

For the faster generic QEMU `virt` developer path on Linux, use `make run-virt`,
`make cluster-virt N=3` and `make test-cluster`. That path directly boots the
kernel/initramfs rather than exercising the flashable card and CM5 devices.

## The cluster desktop

On the workstation, start RemoteOS-SDL listening for the cluster:

```console
remoteos-sdl --listen-tcp 0.0.0.0:17010
```

Under QEMU, start the cluster with the desktop pointed at the host (QEMU's
user network reaches it as 10.0.2.2):

```console
scripts/ssi-qemu cluster 3 10.0.2.2:17010
```

On real hardware set `desktop = WORKSTATION-IP:17010` in `ssi.conf`, or run
`desktop "192.168.1.10:17010"` at any node's shell. The desktop opens a
Cluster monitor, a Mandelbrot computed by every machine (tiles outlined in
each machine's colour; click to zoom), and an Elixir shell window. Power off
the machine named in the menu bar's "drawn by" field: the desktop reappears
from another machine with the same windows. `make test-desktop` checks all of
this against a headless RemoteOS-SDL.

## Watch the cluster

Every member serves a status endpoint on port 80 (`web.port`) and over TLS
on port 443 (`web.tls_port`). The
monitor is one HTML file, `os/ssi/priv/monitor/index.html`; open it from disk
so it keeps working when members, or the whole cluster, are down, and point
it at one or more members:

```text
file:///path/to/index.html#endpoints=192.168.1.21:80,192.168.1.22:80
```

You can also browse to any member (`http://MEMBER/`) and save the page. The
monitor connects to every endpoint you give it, remembers the cluster in the
browser, and shows one verdict with its reasons: **Healthy**, **Degraded** (a
member missing or a service not running), **Split** (members disagree about
the membership), or **Down** (nothing answers; the last known state stays on
screen). It also shows the system as one machine, a card per member
(including how its previous boot ended: cleanly, or by power loss or a
crash), the services, and a timeline of joins, departures, failovers and
boots.

### Act on the cluster from the monitor

Reading needs nothing; acting needs this browser to be paired. In a shell on
any member (console or SSH):

```text
monitor_pair("laptop")
```

prints a one-time code, valid for ten minutes. Enter it under **Control** in
the monitor. The browser makes a key pair whose private half cannot be
copied out of it, and the cluster trusts that key from then on: each member
card gets **restart** and **power off** (each asks for confirmation in the
page), and each service a **move** to another member. Every action appears
in the timeline with the name you paired under. `monitor_keys` lists paired
browsers and `monitor_revoke("laptop")` removes one.

Controls need the page opened from a file or over `https://`; served over
plain HTTP it stays read-only, because browsers allow signing keys only in
secure contexts.

To use TLS, trust the cluster's web CA once in your browser or operating
system: download it from any member (`http://MEMBER/ca.pem`), check its
public-key fingerprint against what `monitor_ca` prints in a shell, and
import it as a certificate authority. Then give endpoints as
`https://MEMBER` (or browse to `https://MEMBER/`). Every member's
certificate names its host name, its addresses, and `localhost`, so an SSH
tunnel or port forward verifies too.

### When the network splits

Services run only in a group of members that holds *quorum*: more than half
of every member the cluster has had, or exactly half including the lowest
host name. So when a switch fails, one side keeps the services and the other
stops them; both keep their shells, files and status endpoint, and the
monitor shows the split with the fenced group marked. `roster` in a shell
lists the members the cluster remembers and whether this group has quorum.

A member you retire for good still counts as absent. Once it is off, remove
it with `cluster_forget("ssi-1a2b3c")`, or a cluster that has lost half its
members will wait for them. Quorum applies from three members on: two
cannot tell a partition from a failure, so a two-member cluster keeps
failing services over as before (`services.partition` changes this).

Under QEMU, node *I*'s endpoint is forwarded to `localhost:808I` and its TLS
endpoint to `localhost:844I`; on emulated CM5 boards to `localhost:818I` and
`localhost:848I`. `make test-monitor` runs the monitor in a
headless browser against four emulated CM5s through a power pull, a clean
restart, a partition into equal halves (one keeps quorum and the service,
the other is fenced) and its heal, and the whole cluster going down and
coming back, then pairs a second browser over TLS and uses every control
(`BOARD=virt` uses KVM nodes and takes minutes, not a quarter of an hour).

## Install on Raspberry Pi Compute Module 5

1. Build the image. Every node of a cluster can use the same image; the
   generated cluster secret is kept in `os/build/cm5/cluster.secret` and
   reused for later images.

   ```console
   cd os
   SSI_CLUSTER=lab SSI_DESKTOP=192.168.1.10:17010 \
   SSI_AUTHORIZED_KEYS=keys.pub make image-cm5   # keys.pub: a file under os/
   python3 scripts/verify_cm5.py                    # layout and driver coverage
   ```

   On macOS, run that verification inside the builder:
   `SSI_WORKDIR=. ./mixdocker.sh 'python3 scripts/verify_cm5.py'`.

   The result is `os/build/cm5/elixirssi-cm5.img` (and `.img.zst`): a FAT32
   boot partition and a 2 GiB ext4 data partition (`SSI_DATA_MB` changes it).

2. Flash each CM5. For eMMC models, fit the CM5 to its IO board, set the
   *disable eMMC boot* jumper (or press nRPIBOOT), connect USB-C to the host
   and run Raspberry Pi's `rpiboot -d mass-storage-gadget64`; the eMMC appears
   as a USB disk. For CM5 Lite, use an SD card. Then:

   ```console
   zstd -dc os/build/cm5/elixirssi-cm5.img.zst | sudo dd of=/dev/sdX bs=4M conv=fsync
   ```

   Raspberry Pi Imager's "Use custom" option also accepts the uncompressed `.img`.

3. Connect every CM5 to one Ethernet switch and power them on. A DHCP server
   is optional: without one, nodes use link-local addresses. They find each
   other within seconds. A shell is available on the IO board's GPIO 14/15
   UART at 115200 baud, on an HDMI display with a USB keyboard, and over SSH
   on every node.

4. Add capacity later by flashing the same image to another CM5 and plugging
   it in. Remove a node by powering it off (`poweroff "ssi-1a2b3c"` from any
   shell stops its services first); its services move and its file blocks are
   re-replicated.

## Try it on emulated CM5 hardware

No boards yet? `os/emulator/` builds a QEMU that emulates the CM5 (BCM2712
and RP1, modelled from public documentation; see
[CM5 emulation](../architecture/cm5-emulation.md)). It boots the image you
would flash:

```console
cd os
make emulator           # pinned QEMU build, ~2 min after the first fetch
make image-cm5
make run-cm5            # one board; its UART0 console is your terminal (Ctrl-A X quits)
make cluster-cm5 N=3    # three boards on one switch, with no DHCP server
make test-cm5           # the cluster acceptance suite on three boards
```

Each board boots its own copy of the image from eMMC
(`os/build/cm5emu/nodeI-IMAGEHASH.img`, inside the cards volume on macOS).
An unchanged image reuses its card; a new image gets a new card and preserves
the older card's state. Acceptance tests use separate disposable cards under
`cm5emu/tests`, so testing does not reset interactive machines. It has one Ethernet port on a shared virtual
switch, a USB keyboard, and a USB Ethernet adapter as a management port
(web endpoint on `localhost:818I`, SSH on `localhost:232I`);
`scripts/ssi-cm5 stop` pulls the power. Emulation
runs without KVM, so boards take about a minute and a half to reach the
shell. It shows that the image and the OS work on the modelled hardware; it
does not replace a run on real CM5s.

## Configuration

`ssi.conf` on the boot partition (template: `ssi.conf.example`, also in
`os/boot/cm5/`) or `ssi.KEY=VALUE` on the kernel command line:

| Key | Default | Meaning |
| --- | --- | --- |
| `cluster` | `ssi` | Cluster name; nodes join only their own cluster |
| `secret` | insecure default | Shared secret; derives the cookie and beacon key |
| `net.IFNAME` | `dhcp,linklocal` | Address policy per interface |
| `cluster_if` | first configured | Interface carrying cluster traffic |
| `peers` | none | Unicast discovery seeds |
| `replicas` | `2` | Copies of each file block |
| `services.partition` | `auto` | `quorum`: under a partition only the group with more than half of the members the cluster has had (or half including the lowest host name) runs services. `available`: every group runs them. `auto`: `quorum` from three members on |
| `desktop`, `desktop.size` | off, `1280x800` | RemoteOS-SDL endpoint for the desktop |
| `ssh.port`, `ssh.password` | `22`, off | SSH server; keys from `/boot/authorized_keys` |
| `web.port` | `80` | Status endpoint for the monitor (`0` disables it) |
| `web.tls_port` | `443` | The same endpoint over TLS, with a certificate from the cluster's web CA (`0` disables it) |
| `data`, `boot` | `auto` | Devices for `/data` and `/boot` (`tmpfs`/`none` to disable) |
| `console.tty` | `tty1` | Virtual console that gets a shell (`off` to disable) |

## Clean up

`make clean` removes the assembled image, release and initramfs. It retains
download/compiler caches, emulator cards and `os/build/cm5/cluster.secret` so
rebuilding does not silently create a different cluster identity. Docker volumes
also survive `clean`. Deleting `os/build/` removes local VM data and the secret;
deleting the cards Docker volume removes its emulated machines' data.

---

## Development workflow

This project uses [Literate AI](https://github.com/NVIDIA-dev/literate-ai) to
keep specifications as durable authority and generate source, current tests, and a
CycloneDX source SBOM into a disposable workspace. The commands below are for
contributors, not end users.

Validate and qualify the actual system image:

```console
make verify-update
make verify
```

The first command builds the image and runs the default, emulator-device and
three-board CM5 acceptance tests, publishing a receipt only on success. The
second checks the receipt against current authority, retained source and local
images. See the [verification contract](framework-flow.md#verification-contract)
for scope and evidence locations. Physical-board qualification is separate.

The inherited greeting Component in `samples/hello-component` is an optional
Literate AI example. Its Python generation recipe does not build ElixirSSI.
Use `make build` and `make run` for the OS.
