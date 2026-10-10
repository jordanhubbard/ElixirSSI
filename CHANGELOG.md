# Changelog

## Unreleased

## 1.2.0 - 2026-10-10

[README.md](https://github.com/jordanhubbard/ElixirSSI/blob/v1.2.0/README.md)

- Qualification: macOS ARM Docker Desktop, three emulated CM5 nodes and the
  packaged browser workspace. Physical Pi and Windows runtime qualification
  are not claimed by this release.
- Fold desktop demos into Projects and simplify Files into local/remote panes with
  directional transfers and contextual tools.
- Link desktop demos to their exact running source. Copy a demo into an editable
  Mix project, test it, and deploy and launch it across the connected cluster.
- Add browser file editing, binary uploads/downloads, project ZIP import/export,
  and reviewed copies between command projects, cluster files and node-local files.
- Link selected host folders with read-only or read-write access. Preview explicit
  bidirectional synchronization, resolve conflicts, reject stale plans, and retain
  synchronization baselines across command-node restarts.
- Give desktop windows independent pixel surfaces so copied graphical demos can
  run alongside their built-in originals. Keep the desktop responsive during tile
  uploads and preserve unrelated applications when deploying or updating a demo.

## 1.1.0 - 2026-10-09

[README.md](https://github.com/jordanhubbard/ElixirSSI/blob/v1.1.0/README.md)

- Qualification: macOS ARM Docker Desktop, three emulated CM5 nodes and the
  fresh packaged Phoenix workflow. Physical Pi and Windows runtime qualification
  are not claimed by this release.
- ElixirSSI: replace installed Python management with an Elixir/OTP command
  node and authenticated Phoenix LiveView workspace. Manage emulated instances,
  register physical Pis, inspect processes and services, and use the cluster
  desktop in the same browser interface.
- ElixirSSI: create and edit Mix projects, run isolated builds, tests and
  evaluation, and deploy runtime dependencies and resources through verified
  SSH connections. Persist deployments across restarts and preserve node data
  when upgrading images; invalid user deployment metadata cannot prevent boot.
- ElixirSSI: package the command release and Elixir emulator supervisor with
  the offline installer. Existing cards, cluster identity and projects survive
  installation adoption.
- ElixirSSI: derive fresh-cluster SSH identities consistently before replication
  converges, avoiding a host-key change after restart; preserve stored legacy keys.
- ElixirSSI: keep Docker Desktop emulator sources and cards on independent
  Linux volume mounts, check mounts before use, and select Docker builds under
  Windows/WSL2 as well as macOS.
- ElixirSSI: fix fresh-checkout Docker kernel builds failing to export
  `modules.tar` when `os/build/` does not exist; cover export directory creation
  independently of verification setup.

## 1.0.0 - 2026-10-08

[README.md](https://github.com/jordanhubbard/ElixirSSI/blob/v1.0.0/README.md)

- ElixirSSI: downloadable Pi 5/CM5 image and ARM64 emulator/development
  installer, with N-node launch, persistent cards, offline browser management,
  pinned RemoteOS desktop packages and checksummed release assets.

- Qualification: three emulated CM5 nodes, offline installation, browser
  management and the RemoteOS desktop passed on Apple Silicon with Docker.
  The image includes Pi 5 and CM5 boot files; physical-board validation is
  still pending. Installation instructions: [distribution guide](https://github.com/jordanhubbard/ElixirSSI/blob/v1.0.0/docs/user/distribution.md).

- ElixirSSI: verified that inter-node IPC and distributed computation use BEAM
  processes over TLS. Load-aware task dispatch and retry complement
  checkpoint-based service failover; long-lived service placement uses hashing
  or explicit migration, not automatic CPU-driven migration.

- ElixirSSI: project verification now declares the actual system-image Make suite,
  with `make verify-update` to run it and `make verify` to check authority,
  retained source and image currency. The inherited greeting sample remains
  separate from OS qualification.

- ElixirSSI: standard root `build`, `run`, `test`, and `clean` targets now
  select the flashable CM5 image and full CM5 emulator path. The generic
  machine remains available as `run-virt`; clean preserves the cluster secret
  and emulated cards. Docker-hosted CM5 emulation boots the flashable image on
  macOS and passes the three-board cluster acceptance suite.
- ElixirSSI: builds on macOS through Docker using Apple Make. The kernel and
  its case-sensitive source and module files stay on Linux filesystems during
  compilation and initramfs assembly; finished artifacts appear in `os/build/`.
  Native Linux builds remain available.
- ElixirSSI: a stand-alone operating system with the Erlang BEAM as PID 1 and
  Elixir as the system language, booting the Raspberry Pi Compute Module 5
  (and the identical kernel under QEMU/KVM). Any number of nodes form one
  single system image: signed zero-configuration discovery, a CRDT-replicated
  system store, one filesystem namespace (`/`, `/proc`, `/node/HOST`) with
  replicated content blobs, a cluster-wide process table and scheduler,
  failover and live migration of services, an Elixir shell on every console
  and over SSH, and a RemoteOS-SDL cluster desktop that itself fails over
  between nodes with its windows and application state. `make image-cm5`
  builds the CM5 eMMC/SD image.
- ElixirSSI: cluster distribution now runs over TLS 1.3 with mutual
  certificate verification, using a certificate authority every node derives
  from the cluster secret; nodes without the secret cannot join or read
  cluster traffic.
- ElixirSSI: a second Elixir shell runs on the first virtual console (the HDMI
  display and a USB keyboard on a CM5), configurable with `console.tty`.
- ElixirSSI: an emulated Compute Module 5 (`make emulator`). QEMU with the
  pinned rpi5_machine BCM2712 model gains an RP1 south bridge (MSI-X,
  clocks, GPIO, UARTs, Gigabit Ethernet, USB) and a `raspi-cm5` board with
  eMMC, modelled from public documentation. `make test-cm5` boots the flashable
  image on three emulated boards and runs the cluster suite. Two QEMU defects
  it exposed are fixed: SDHCI Auto CMD23, and DWC3's ERSTBA latch.
- ElixirSSI: the CM5 image's console is now RP1's UART0 on GPIO 14/15
  (`dtparam=uart0_console`). On a CM5 `serial0` otherwise means the debug
  UART, whose connector is not fitted on every module.
- ElixirSSI: a cluster monitor that outlives the cluster. Every member serves
  a read-only status endpoint (`web.port`, default 80: JSON snapshot and a
  WebSocket stream); the monitor is one self-contained HTML page, run from a
  file or saved from any member, that watches every member at once and
  shows the system as one machine, each member (including how its previous
  boot ended), the services, a timeline of joins, departures, failovers and
  boots, and one verdict with reasons — healthy, degraded, split or down —
  keeping the last known cluster on screen when nothing answers.
  `make test-monitor` drives it in a headless browser across four emulated
  CM5 boards, which gain a USB Ethernet management port and a partitionable
  switch.
- ElixirSSI: fixed a member failing to boot after a power cut. The store log
  could end in zeros the file was extended by but never written, and replay
  raised on them; it now stops at the first undecodable record and cuts the
  log back to the last whole one.
- ElixirSSI: the monitor can act on the cluster — move a service, restart or
  power off a member — once the browser is paired with a one-time code from
  `monitor_pair` in a shell. The browser keeps a non-extractable ECDSA key and
  signs each request over a per-connection challenge, so requests cannot be
  forged or replayed; each one is journalled with who made it, and
  `monitor_revoke` withdraws a key everywhere at once. Every member also
  serves the endpoint over TLS (`web.tls_port`, default 443) with a
  certificate from a web CA derived from the cluster secret (`/ca.pem`,
  fingerprint shown by `monitor_ca`).
- ElixirSSI: a network partition no longer splits the system in two. The
  cluster remembers every member it has had (`roster`), and only a group
  holding more than half of them (or exactly half including the lowest host
  name) runs services; the other group stops its instances and says why in
  the timeline, while its shell, files and status endpoint keep working. The
  monitor names the group holding quorum and marks the fenced one.
  Quorum applies from three remembered members on (`services.partition`,
  default `auto`), so two-member clusters fail over as before;
  `cluster_forget` retires a member for good. Stops a
  service manager makes itself (hand-offs, fencing) now appear in the
  timeline.

- Initialized the project with Literate AI's specification-led lifecycle and durable
  user-directed work queue.
