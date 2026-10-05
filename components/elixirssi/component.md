---
namespace: elixirssi
version: 0.1.0
display_name: ElixirSSI single-system-image operating system
profiles: []
sample: false
provides: []
requires: []
authoring_inputs:
  - kind: specification-to-source-skill
    uri: skills/specification-to-source/elixir-beam-system/SKILL.md
workflow_definition: workflows/production/staging/dev/workflow.md
routing_policy: routing/production/staging/dev/routing.json
flavor_slots: []
entrypoints: []
acceptance_contracts: []
source_dependencies: []
---
# ElixirSSI

A stand-alone operating system whose runtime is the Erlang BEAM and whose system
programming language is Elixir. It runs natively on the Raspberry Pi Compute
Module 5, and any number of CM5 machines on one network present themselves to
their users as **one system**: one membership, one process table, one file
namespace, one scheduler, one set of services, one desktop.

The reference implementation lives in `os/` (Elixir application `os/ssi`, C
substrate `os/substrate`, kernel fragment `os/kernel`, image tooling
`os/scripts`). The design rationale is in
[docs/architecture/elixirssi.md](../../docs/architecture/elixirssi.md).

## Substrate

- The machine boots the Raspberry Pi Linux kernel (`rpi-6.18.y`,
  `bcm2712_defconfig` plus `os/kernel/elixirssi.config`) as a hardware
  abstraction layer only. The same kernel image MUST boot a CM5 and the
  QEMU/KVM `virt` machine used for development.
- The initramfs is the entire root filesystem. Its `/init` is a static C shim
  that mounts `/proc`, `/sys`, `/dev`, `/dev/pts`, `/dev/shm`, `/tmp` and
  `/run`, attaches `/dev/console`, and then *execs* the BEAM, which therefore
  runs as PID 1. No other Linux userland program (shell, init system, udev,
  DHCP client, epmd) is present or started.
- System calls without a portable BEAM API (mount, reboot, sethostname,
  interface and route configuration, `finit_module`, statvfs, the kernel log)
  are exposed through one policy-free NIF. Every decision about when and how
  to use them is made in Elixir.
- Every boot-path device of the CM5 and CM5 Lite device trees (eMMC/SD
  controller, PCIe root complex, RP1 south bridge, RP1 Ethernet, PL011 UART,
  RP1 GPIO) MUST have a driver built into the kernel. Other devices get
  drivers loaded from the initramfs by matching sysfs `modalias` strings
  against `modules.alias`.

## Configuration

Configuration comes from built-in defaults, then `ssi.conf` on the FAT boot
partition, then `ssi.KEY=VALUE` words on the kernel command line, in
increasing precedence. All nodes of a cluster share `cluster` and `secret`;
the same image may be flashed to every node. Using the published default
secret MUST be announced on every console and SSH login.

## Networking

- Each Ethernet interface follows its policy `net.IFNAME`, a comma-separated
  list tried in order: `dhcp` (an Elixir DHCPv4 client, lease renewed at T1),
  `linklocal` (a stable 169.254/16 address derived from the MAC), `static:`,
  or `off`. The default is `dhcp,linklocal`, so a cluster on a bare switch
  with no infrastructure still forms.
- The cluster address is that of `cluster_if`, or the first interface
  configured. The node's name is `ssi@<cluster address>`.

## Cluster formation and membership

- BEAM distribution listens on TCP 4370 on the cluster address only. Node
  names map to that port without an epmd daemon.
- Distribution runs over TLS 1.3 with mutual certificate verification. Every
  node derives the same cluster CA (Ed25519 key, byte-identical certificate)
  from the cluster secret and issues itself a certificate for a fresh key at
  boot; a host without the secret can neither join nor read cluster traffic.
- The distribution cookie, the CA and the discovery signing key are derived
  from the cluster secret. Nodes MUST NOT need any per-node credential.
- Every node multicasts an HMAC-SHA256-signed beacon every two seconds and
  unicasts it to configured `peers`. A node receiving a valid beacon of its
  own cluster from an unconnected node connects to it. A node that joins
  connects to every member the joined node knows, so all members converge on
  one membership view.
- Membership is every connected node. A node that stops responding is
  removed after the distribution tick timeout (8 s).
- The *roster* is every member the cluster has had, kept in the replicated
  state by member id (the host name; the node name in hosted mode) with the
  node name it last used. Every member keeps its own entry current. A member
  leaves the roster only by operator command (`cluster_forget`), and only
  while it is down.
- A group of connected members holds *quorum* when it has more than half of
  the roster, or exactly half including the roster's lowest member id.
- The aggregate machine (`SSI.Cluster.summary/0`) reports the sum of members'
  cores, schedulers and memory.

## Replicated state

- System state is a last-writer-wins map replicated in full to every member,
  timestamped with hybrid logical clocks. Merge MUST be commutative,
  associative and idempotent; deletes are tombstones.
- Writes are pushed to all members and MUST also converge without the push,
  through periodic and on-join anti-entropy over per-bucket digests.
- Each node persists the map in an append-only log on its data partition and
  replays it at boot. A power cut can leave a torn final record or a tail of
  zeros the file was extended by but never written; replay stops at the
  first record that does not decode and cuts the log back to the last whole
  record, so the node boots and later appends stay readable.

## Filesystem

- Every node presents one namespace: `/` is the cluster filesystem, `/proc`
  renders the live cluster as text, and `/node/HOST/...` reaches one member's
  local filesystem.
- Cluster-filesystem metadata lives in the replicated map; content is split
  into 1 MiB content-addressed blobs stored on `replicas` members chosen by
  rendezvous hashing. A file written on any node MUST be readable, with the
  same bytes, from every other node.
- On membership change each node re-replicates blobs whose holders lack them
  and removes copies it no longer needs once enough holders confirm a copy.
- Unreferenced blobs are collected after a grace period.

## Processes and computation

- `SSI.Proc.ps/1` lists the processes of every member. Shell output names a
  process `HOST:<0.N.0>`, a string that resolves back to the pid from any node.
- `SSI.Sched` places a computation on the least loaded member by scheduler
  utilisation and run-queue length. `pmap/3` and `each/4` spread items over
  every scheduler of every member, start using members that join mid-run, and
  re-run items whose member fails.

## Services

- A service is a named `GenServer` registered cluster-wide. Exactly one
  instance runs, on its pinned member if alive, otherwise on the member that
  ranks highest for its name under rendezvous hashing.
- When the owning member fails, another member MUST start the service.
  `SSI.Service.move/2` migrates a running service; the new instance starts
  only after the old one has stopped, and restores the state the old one
  checkpointed.
- A freshly booted node waits a settle period before claiming services, so a
  rejoining node does not briefly run duplicates.
- Services run only in a group holding quorum, so a partition leaves them
  running on one side. A group without quorum MUST stop its instances and
  journal why; services have no owner there. The replicated state, files,
  shell and status endpoint stay available in every group. Fencing is not a
  lease: the two sides detect the partition independently, so instances may
  overlap for at most the difference between their detection times.
- `services.partition` selects the policy: `quorum`; `available` (every
  group runs services, as before quorum existed); or `auto`, the default:
  `quorum` once the roster has three members, `available` before, since two
  members cannot tell a partition from a failure and would lose every
  service with the tie-breaking member.

## Shell and remote access

- The serial console, the first virtual console (`tty1`: the HDMI display
  and a USB keyboard on a CM5) and every SSH session are Elixir shells with
  system commands (`nodes`, `ps`, `top`, `ls`, `cat`, `df`, `free`, `run`, `pmap`,
  `services`, `migrate`, `mandel`, `bench`, `reboot`, ...) imported.
- SSH is served on every member with one cluster-wide host key. Keys come from
  `/boot/authorized_keys` and the replicated map; password login is enabled
  only when configured.
- Restart and power-off stop services (so they hand off) before calling
  reboot(2). The BEAM never exits on its own, since that would panic the
  kernel.

## Desktop

- The desktop is a service that speaks RemoteOS protocol v2 to a
  RemoteOS-SDL process on the user's workstation. It renders a menu bar
  naming the member drawing it, a dock, and movable windows: a Cluster
  monitor, a cluster-wide process view, a Mandelbrot renderer whose tiles are
  computed across the cluster and outlined in the colour of the computing
  member, and an Elixir shell.
- When the member drawing the desktop fails, the desktop MUST restart on
  another member, reconnect, and restore its windows and their application
  state.

## Status monitor

Every member serves the status endpoint, and the monitor watches and
controls the system from outside it; both are specified in
[ElixirSSI monitor](../elixirssi-monitor/component.md).

## Images

- `make` produces the kernel and initramfs; `make image-cm5` produces an MBR
  image with a FAT32 boot partition (`config.txt`, `cmdline.txt`,
  `kernel_2712.img`, initramfs, BCM2712 device trees and overlays,
  `ssi.conf`) and an ext4 data partition.

## Emulated hardware

- `make emulator` builds a QEMU with a `raspi-cm5` machine. It extends the
  pinned rpi5_machine BCM2712 model with an RP1 south bridge (PCI function and
  MSI-X translation, clocks, GPIO, UART0-5, Gigabit Ethernet, two USB hosts)
  and eMMC on SDIO1. Its device models MUST be derived from public
  documentation, and each MUST state its fidelity level (surrogate, driver
  contract, or hardware-verified) in `docs/architecture/cm5-emulation.md`.
- An emulated board MUST boot the unmodified `elixirssi-cm5.img` from its eMMC,
  with boot files, device tree and command line chosen as the CM5's firmware
  chooses them from the image's boot partition.
- For tests, an emulated board (and a `virt` node) has a management port on
  QEMU user networking through which the host reaches its web endpoint
  (plain and TLS) and SSH; on a CM5 board it is a USB Ethernet adapter. The cluster port is
  connected through a hub to two virtual switches, of which a test plugs in
  one at a time, so it can partition the cluster without the members seeing
  a link change.
- Emulated boards running the image MUST pass the same cluster acceptance
  checks as the QEMU/KVM `virt` nodes. Evidence from emulation MUST NOT be
  presented as hardware validation.

## Acceptance

| Scenario | Evidence |
| --- | --- |
| Configuration, DHCP codec, module matching, paths, beacon authentication, epmd mapping | `make test` (`unit_test.exs`) |
| Deterministic cluster CA; TLS distribution between separate BEAMs; intruder refused | `make test` (`tls_test.exs`) |
| Store convergence, anti-entropy, shared files, blob repair, process table, `pmap` with node failure, service failover and migration | `make test` (`cluster_test.exs`, real peer BEAMs) |
| RemoteOS framing, desktop drawing, tile placement, app restore | `make test` (`remote_test.exs`, `desktop_test.exs`) |
| IEx over the terminal I/O server (multi-line input, `IO.gets`) | `make test` (`console_test.exs`) |
| N CM5-kernel VMs form one system over TLS distribution; failover after killing a VM; rejoin with persistent state; SSH; keyboard input to the tty1 shell | `make test-cluster` |
| Desktop on headless RemoteOS-SDL, input injection, failover of the desktop | `make test-desktop` |
| CM5 image layout and boot-path driver coverage | `python3 os/scripts/verify_cm5.py` |
| Emulated RP1 at register level: identity, BARs, MSI-X edge and IACK semantics, atomic aliases, GPIO and its interrupts, PLL lock | `make test-emulator` |
| Three emulated CM5s boot the flashable image from eMMC, show CM5 hardware to Linux, and pass the cluster suite, including USB keyboard input to tty1 and the console on RP1 UART0 | `make test-cm5` |
| A store log left torn or zero-filled by a power cut still boots and keeps appending readably | `make test` (`store_log_test.exs`) |
| Roster enrolment, majority and tie-break, fencing and recovery of a service, `cluster_forget`, `services.partition = available` | `make test` (`quorum_test.exs`, real peer BEAMs) |
