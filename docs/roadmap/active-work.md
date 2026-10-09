# Active work

This file is the durable resumption queue for user-directed and discovered work. Before
implementation, follow `skills/agent/record-user-directed-work/SKILL.md`.
Keep detailed designs in focused roadmap documents and link them here.

## Detailed-roadmap lifecycle

This file is the sole resumable queue. Create a supporting file beneath `docs/roadmap/`
only when one item cannot keep a program's rationale, ordering, and acceptance contract
readable. Put this visible header immediately after the detailed document's title:

```markdown
- **Status:** active
- **Owning queue item:** [AREA-NNN](active-work.md#area-nnn-heading)
- **Completion / archival evidence:** pending while AREA-NNN remains open
```

Status is exactly `active`, `partial`, `deferred`, `completed`, or `historical`. The
owner must resolve to a checkbox or named program heading in this file. A terminal state
requires linked evidence. Keep a completed plan here only when doing so preserves useful
inbound links; move substantial closed programs beneath `docs/history/roadmap/`, retain
their owner, and mark them `historical`. Do not create a separate file for an ordinary
queue item or let `docs/roadmap/` become a plan archive.

## P0

Check the parent only after every required subtask and evidence item passes. Add the
release-visible outcome to `CHANGELOG.md`; Git preserves prior queue states.

### [x] SSI-001 — Elixir/BEAM single-system-image OS for Raspberry Pi CM5 clusters

- **Priority:** P0
- **Owner:** project core (os/)
- **Direction:** Build a stand-alone OS with the BEAM as its runtime and Elixir as the system programming language, inspired by PythonOS, RubyOS and RemoteOS-SDL; run natively on the Raspberry Pi Compute Module 5; present any number of CM5 nodes as one single-system-image cluster for computer-scientist users; offer a RemoteOS-SDL cluster desktop demo.
- **Conclusion:** Linux (Raspberry Pi rpi-6.18.y, one image for CM5 and QEMU/KVM virt) is the hardware substrate only; a tiny C shim execs the BEAM as PID 1 and Elixir owns init, devices, networking, storage, the cluster, shell and desktop. A bare-metal ERTS port was rejected: CM5 networking sits behind PCIe->RP1->GEM and cannot be emulated or verified without hardware, while the SSI value lives above the driver layer. SSI is built from BEAM distribution with an Elixir epmd replacement, signed multicast discovery, a CRDT replicated store, a cluster VFS, cluster-wide process table and placement, failover services, and a RemoteOS protocol-v2 desktop that fails over between nodes.
- **Depends on:** none
- **Implementation:**
  - [x] Pinned OTP/Elixir source toolchain image (`os/toolchain/`, OTP 29.1.1 + Elixir 1.20.4 from checksummed source on musl/arm64)
  - [x] CM5+virt kernel fragment and build (`os/kernel/elixirssi.config` over `bcm2712_defconfig`, rpi-6.18.y)
  - [x] PID-1 shim and syscall NIF (`os/substrate/`)
  - [x] Elixir OS: boot, devices, net, cluster, store, VFS, processes, services, shell, ssh (`os/ssi/lib/ssi/`)
  - [x] RemoteOS desktop with cluster apps, failover and per-app state restore
  - [x] initramfs, QEMU cluster runner and CM5 eMMC image builder (`os/scripts/`)
  - [x] Documentation and component specifications (`components/elixirssi/component.md`, `docs/architecture/elixirssi.md`, getting started)
- **Evidence:**
  - [x] Host ExUnit suite passes — `make test`: 22 tests incl. real multi-node peers (2026-10-01)
  - [x] Single node boots to Elixir shell in QEMU/KVM with the shipped kernel — 6.18.54-elixirssi, ~3 s BEAM-to-prompt (2026-10-01)
  - [x] Three-node QEMU cluster forms one system image (ps, fs, failover) under automated test — `make test-cluster` 17/17; service failover 9–10 s after VM kill (2026-10-01)
  - [x] Headless RemoteOS-SDL desktop smoke captures a cluster desktop frame — `make test-desktop` 26/26 incl. input injection and desktop failover with state (2026-10-01)
  - [x] CM5 eMMC image builds with bcm2712-rpi-cm5 DTBs, config.txt and initramfs — `make image-cm5`; `verify_cm5.py` 21/21 incl. boot-path driver coverage (2026-10-01)

### [ ] SSI-002 — Validate ElixirSSI on physical Compute Module 5 hardware

- **Priority:** P1
- **Owner:** project core (os/)
- **Direction:** Run the system on real CM5 boards, not only the identical kernel under KVM.
- **Conclusion:** The CM5 boot path is verified statically (device-tree driver coverage, image layout, kernel header), the kernel and initramfs under KVM, and since SSI-005 the flashable image itself on emulated CM5 boards built from public documentation. Emulation models devices at the driver-contract level, not silicon; observing the system on physical CM5s closes the remaining gap.
- **Depends on:** SSI-001
- **Implementation:**
  - [ ] Flash elixirssi-cm5.img to a CM5 on a CM5 IO board; capture the serial boot log
  - [ ] Bring up a 3-node CM5 cluster on one switch, with and without DHCP
  - [ ] Adapt test_cluster.py to drive hardware nodes over SSH
- **Evidence:**
  - [ ] Serial log shows the ElixirSSI banner on CM5 and CM5 Lite
  - [ ] Three CM5s form one system, fail over a service, and draw the desktop

### [x] SSI-003 — Encrypt and mutually authenticate cluster traffic

- **Priority:** P2
- **Owner:** project core (os/)
- **Direction:** Make clusters safe on shared networks, not only dedicated ones.
- **Conclusion:** Distribution is authenticated by a cookie derived from the cluster secret but is not encrypted. OTP TLS distribution with per-node certificates issued by a cluster CA derived at boot removes that limit without per-node provisioning.
- **Depends on:** SSI-001
- **Implementation:**
  - [x] Derive a cluster CA and per-node certificates at boot (`SSI.Cluster.TLS`; deterministic Ed25519 CA)
  - [x] Switch to inet_tls_dist with verify_peer (`rel/vm.args.eex`, `rel/overlays/ssl_dist.conf`)
- **Evidence:**
  - [x] Distribution between nodes is TLS with peer verification — `tls_test.exs`: separate inet_tls BEAMs pong with the secret, pang without (2026-10-02)
  - [x] make test-cluster passes over TLS distribution — 18/18, connections report protocol :tls (2026-10-02)

### [ ] SSI-004 — Shell on the HDMI console

- **Priority:** P3
- **Owner:** project core (os/)
- **Direction:** Offer the system shell on a directly attached display and keyboard.
- **Conclusion:** The shell is on the UART and SSH; HDMI shows kernel messages only. A second IEx server on /dev/tty1 needs a VT-aware IO server.
- **Depends on:** SSI-001
- **Implementation:**
  - [x] Run an IEx server on /dev/tty1 with a VT-aware IO server (`SSI.Console.TTY`, `SSI.Console.IOServer`, `open_tty` NIF)
  - [x] Virtio keyboard in the kernel and QEMU runner so the VT shell is testable (`CONFIG_VIRTIO_INPUT`)
- **Evidence:**
  - [x] VT shell under QEMU/KVM with the shipped kernel — `make test-cluster`: typed `node()` evaluated on tty1, read back from `/dev/vcs1`; `console_test.exs` (2026-10-02)
  - [ ] A keyboard and display attached to a CM5 reach the Elixir shell — blocked on SSI-002 hardware

### [x] SSI-005 — Emulate the Compute Module 5 hardware from public documentation

- **Priority:** P1
- **Owner:** project core (os/emulator)
- **Direction:** Emulate the CM5 hardware from public documentation, as the uConsole project did for the CM4, so the flashable image can be booted and the cluster tested on modelled BCM2712 and RP1 hardware.
- **Conclusion:** Adopt rpi5_machine (pinned, GPL-2.0-or-later QEMU model of the BCM2712: CPUs, GIC, UART10, SD hosts, firmware mailbox, PCIe root complexes, MIP) and add what the CM5 boot path needs and it lacks: an RP1 model (PCI function, MSI-X with IACK, SYSINFO, clocks/PLLs, GPIO, UART0-5, Cadence GEM Ethernet, two DWC3 xHCI hosts), a raspi-cm5 board with eMMC, a CM5 mode for its firmware-emulating boot script, and two QEMU fixes the CM5 exercises (SDHCI Auto CMD23 for eMMC writes; DWC3 latching ERSTBA on its low dword). Sources: the RP1 peripherals datasheet, the CM5 datasheets, the Linux drivers and device trees, and lspci of real RP1 hardware. Emulation is evidence for the model, not for silicon; SSI-002 stays open.
- **Depends on:** SSI-001
- **Implementation:**
  - [x] Pinned emulator build: rpi5_machine + QEMU v11.1.1 + os/emulator patches (os/emulator/build-qemu.sh, make emulator)
  - [x] RP1 model (os/emulator/qemu/overlay/hw/misc/rp1.c)
  - [x] raspi-cm5 machine and rpi5-boot --board cm5 (os/emulator/base-patches/)
  - [x] QEMU fixes: SDHCI Auto CMD23, DWC3 ERSTBA latch (os/emulator/qemu/patches/)
  - [x] CM5 board runner and cluster test profile (os/scripts/ssi-cm5, test_cluster.py --board cm5)
  - [x] Emulation design and fidelity record (docs/architecture/cm5-emulation.md)
- **Evidence:**
  - [x] Register-level RP1 tests pass without an OS — `make test-emulator`: 10/10 (identity, BARs, MSI-X edge and IACK delivery, aliases, GPIO interrupts, PLL lock, GEM identity) (2026-10-02)
  - [x] Three emulated CM5 boards boot the unmodified flashable image from eMMC and pass the cluster acceptance suite — `make test-cm5`: 29/29, incl. CM5 identity, RP1 at lspci's BARs, eth0 via rp1_irq_chip, eMMC, USB keyboard to tty1, console on RP1 UART0, failover 9.1 s after a power pull; `make test-cluster` (virt) still 20/20 (2026-10-02)

### [x] SSI-006 — Cluster status monitor that outlives the cluster

- **Priority:** P1
- **Owner:** project core (os/ssi, os/scripts)
- **Direction:** Give users a browser UI for the cluster's status that shows both how the single system image behaves as a whole and how each member is doing, and that keeps working when the cluster is partly or entirely down: it must say whether the cluster is up, down, healthy or degraded, and why. Test everything end to end on a cluster of four emulated CM5 boards.
- **Conclusion:** A monitor served by the cluster disappears exactly when it is needed, and WASM does not change what a browser can observe (HTTP/WebSocket only), so the monitor is one self-contained static page that runs from a local file (or a copy saved from any member) and the cluster side is a small read-only status endpoint on every member, not a singleton service: every member already holds the cluster-wide data. The page connects to every known member at once, remembers the last known cluster in the browser, compares members' views to detect a split, classifies unanswering members, and reads each member's record of how its previous boot ended. Controls (migrate, reboot) and TLS for the endpoint are out of scope until authentication is designed.
- **Depends on:** SSI-001, SSI-005
- **Implementation:**
  - [x] Specify the monitor, status endpoint and boot record (now components/elixirssi-monitor/component.md, docs/architecture/elixirssi.md "Watching the system from outside")
  - [x] SSI.Status: snapshot of system and members, event journal, previous-boot record (os/ssi/lib/ssi/status.ex, status/)
  - [x] SSI.Web: HTTP and WebSocket status endpoint on every member (web.port; os/ssi/lib/ssi/web.ex)
  - [x] Monitor page (os/ssi/priv/monitor/index.html), served by members and runnable from a file
  - [x] Emulated management port and partitionable switch for boards (ssi-cm5: USB Ethernet; ssi-qemu: web forward; both: hub to switch A, hot-added switch B on its own port)
  - [x] End-to-end browser test across four boards (os/scripts/test_monitor.py, scripts/browser/drive.mjs with pinned playwright-core 1.62.1, make test-monitor)
  - [x] Discovered: a member could not boot after a power cut left zeros at the end of its store log (replay raised, the BEAM exited, the kernel panicked); replay now stops at the first undecodable record and truncates the log there (os/ssi/lib/ssi/store.ex, store_log_test.exs)
- **Evidence:**
  - [x] make test covers the snapshot, journal, boot record, HTTP and WebSocket endpoint, and torn store logs — 40 passed (status_test.exs, web_test.exs, store_log_test.exs) (2026-10-02)
  - [x] Four emulated CM5 boards: the monitor shows healthy, a power pull (degraded, failover time, unclean previous boot), a partition (split) and its heal, the whole cluster down (last known state kept across a reload), and recovery — `make test-monitor`: 24/24; degraded 9.8 s after the pull, failover with 8 s unavailability in the timeline, split shown 18.8 s after the cut and held, healed in 1.5 s, down at once with every member remembered, healthy again 41 s after a cold start, no page errors, no overflow at 390 px (2026-10-02)
  - [x] The same browser suite passes on four virt nodes — `make test-monitor BOARD=virt`: 24/24 (2026-10-02)
  - [x] Existing suites still pass with the new runners (hub, management port) — `make test-cluster` 20/20, `make test-cm5` 29/29 (2026-10-02)

### [x] SSI-007 — Authenticated controls and TLS for the status endpoint

- **Priority:** P3
- **Owner:** project core (os/ssi)
- **Direction:** Follow-up from SSI-006: let the monitor act on the cluster (migrate a service, restart or power off a member) and reach members over TLS, once reaching the port is no longer enough to change the system.
- **Conclusion:** Spec in components/elixirssi-monitor/component.md "Monitor controls and TLS" (the monitor became its own component when the ElixirSSI spec outgrew one document). Authentication: each browser holds a non-extractable ECDSA P-256 key (WebCrypto, IndexedDB); an operator who can already log in (console or SSH) issues a one-time 80-bit pairing code (`monitor_pair`), the monitor proves the code with an HMAC over the connection challenge, and the key is recorded in the replicated store. Every control request is signed over the connection's challenge with a rising sequence number (no forgery, alteration or replay), so it is safe over plain HTTP too; TLS adds confidentiality and server authentication. TLS uses a separate *web CA* with an ECDSA P-256 key derived from the secret, because browsers reject the Ed25519 distribution CA; leaf certificates name the host, localhost and the current addresses, are sent without the CA, and use a key derived from the secret and host name (stable across boots, so pinnable; TLS 1.3 key exchange keeps forward secrecy). Controls need WebCrypto, so they exist only from a local file or https.
- **Depends on:** SSI-006
- **Implementation:**
  - [x] Spec: Monitor controls and TLS (component.md), architecture rationale
  - [x] SSI.Web.Control: trusted keys, pairing codes, request verification, actions, journal `control` events, shell commands
  - [x] SSI.Web.TLS: derived web CA, per-address leaf certificates; TLS listener on web.tls_port; GET /ca.pem
  - [x] Monitor: pairing, key in IndexedDB, signed requests, member and service controls with in-page confirmation, wss endpoints
  - [x] Emulation: forward the TLS port on the management port (CM5 8480+I, virt 8440+I)
  - [x] control_test.exs; make test-monitor control and TLS phase
  - [x] Split the monitor into its own component (components/elixirssi-monitor) when the ElixirSSI spec passed the 16 KiB description limit
- **Evidence:**
  - [x] Unauthenticated requests cannot change state; authenticated ones can, under make test-monitor: four emulated CM5s 38/38 and four virt nodes 38/38 (2026-10-03). Forged, unsigned and wrong-code requests and POST are refused with nothing changed; a browser paired with a shell code moves a service, restarts a member (after in-page confirmation) and powers one off (it returns reporting a clean power-off); each action is journalled with the operator's name; revocation removes the controls at once.
  - [x] Every member's TLS certificate verifies against the web CA (fetched from /ca.pem) for its own host name with Python's ssl, another name is refused, and the browser reaches all members over wss:// pinned to exactly those certificates (headless Chromium cannot import a CA).
  - [x] make test: 45 passed, including control_test.exs (pairing once and expiry, untrusted/bad/missing/altered signatures, replay on the same and another connection, revocation, hosted refusal, web CA determinism, TLS with IP and name verification, another cluster's CA refused).

### [x] SSI-008 — Run services only on the side of a partition that holds quorum

- **Priority:** P1
- **Owner:** project core (os/ssi)
- **Direction:** Next non-hardware work, chosen from the documented limits: under a network partition each side runs its own copy of every service, so the single system image briefly becomes two systems. Make a partition leave exactly one side running services.
- **Conclusion:** Membership today is just the connected set, so a side cannot tell it is the minority. Keep a replicated roster of the members the cluster has had, keyed by host name (stable, MAC-derived or configured; node names follow addresses). A side holds quorum when it has more than half the roster, or exactly half including the roster's lowest host name (deterministic tie-break). Service managers run services only with quorum and stop their instances when it is lost, so the minority fences itself; the store, filesystem, shell and status endpoint stay available everywhere (CRDT). Retired members leave the roster only by explicit operator command (cluster_forget). services.partition = auto (default) requires quorum from three remembered members on; two members cannot tell a partition from a failure, and quorum would turn the tie-breaker's failure into losing every service (found by make test-desktop, a two-node failover); quorum and available force either. The status snapshot and monitor show the roster, quorum and which side is fenced. Not a lease: an overlap bounded by the two sides' failure-detection skew remains, and is documented.
- **Depends on:** SSI-001, SSI-006
- **Implementation:**
  - [x] Spec: services under partition, roster and quorum (components/elixirssi), monitor quorum display (components/elixirssi-monitor); architecture "Services under partition: quorum"
  - [x] SSI.Cluster.Roster: replicated roster, quorum/0, forget/1; shell cluster_forget, roster (os/ssi/lib/ssi/cluster/roster.ex)
  - [x] Service manager: run services only with quorum, journal quorum changes; services.partition config (auto, quorum, available)
  - [x] Status snapshot quorum; monitor shows quorum (fact, split reasons, fenced group tags, degraded without quorum, timeline)
  - [x] Tests: quorum_test.exs (roster, tie-break, fencing with peers); test-monitor partition expects one copy on the quorum side
  - [x] Discovered: stops a service manager makes itself (hand-offs, and now fencing) were never journalled, because the instance left the manager's table before its exit arrived; they are recorded when the stop is issued (os/ssi/lib/ssi/service.ex)
  - [x] Discovered: test peers stopped by one test file stayed in the hosted store's roster and fenced later files; start_peers/stop_peers forget absent members (test_helper.exs)
- **Evidence:**
  - [x] make test passes including quorum_test.exs — 49 passed (2026-10-04)
  - [x] make test-monitor (4 emulated CM5s, 2|2 split): the service runs on exactly one side throughout the partition; the monitor names the fenced side — 39/39 on the final build: split shown in 18.5 s, ssi-c50001+ssi-c50002 hold quorum (2 of 4, tie-breaker), the counter ran only on ssi-c50001 for the whole hold, ssi-c50003/4 shown fenced with "quorum lost" in the timeline (the fenced side stopped it 3 s before the quorum side started it), healed in 1.3 s with one copy (2026-10-04)
  - [x] make test-cluster and make test-monitor BOARD=virt still pass — 20/20 and 39/39; make test-cm5 29/29; make test-desktop (two nodes) 29/29 once services.partition = auto exempted two-member rosters — it failed 24/29 with quorum required, the survivor of a two-node failover lacking quorum (2026-10-04)

### [x] SSI-009 — Build from macOS through Docker

- **Priority:** P1
- **Owner:** project core (os build tooling)
- **Direction:** Make this checkout build on the Mac using Docker for Linux tools.
- **Conclusion:** The default build invoked Apple Make 3.81 and a Linux cross compiler on macOS. The macOS path now builds the kernel on a case-sensitive Docker volume and assembles the initramfs inside Linux, retaining the native Linux path and pinned runtime. Module filenames also differ only by case (xt_RATEEST.ko and xt_rateest.ko): export them as modules.tar and unpack only inside Linux, with separate metadata for the hardware-image verifier. Snapshot the long-running kernel script before execution so edits cannot corrupt the running shell's input.
- **Depends on:** SSI-001
- **Implementation:**
  - [x] Provide a Docker kernel build with persistent case-sensitive storage and exported build artifacts
  - [x] Make source checksums and initramfs assembly portable and document the macOS build
  - [x] Preserve case-distinct modules through archive transport and check their dependency closure in the generated initramfs
- **Evidence:**
  - [x] Default make produces the ARM64 kernel and initramfs from this macOS checkout — Apple Make 3.81, Docker ARM64, kernel 6.18.54-elixirssi+, 942 modules; kernel SHA-256 d7f5c3037442f7a0ee6144929f31e9634a0945d4e7ca924ca6e5185260c2123f, initramfs SHA-256 319299a4e234d0367af0f5a0d799fa3782430680e117a296fa0492cc43c10a7f (2026-10-05).
  - [x] make test passes the Elixir unit and multi-node suite — 49 passed (2026-10-05).
  - [x] Incremental build and kernel container failure propagation checks pass — plain make reports nothing to do; python3 os/scripts/test_build.py passes 4 checks covering failure exits, paths with spaces, cache reuse, distinct module contents and complete module dependencies (2026-10-05).
  - [x] Build the CM5 image and pass its static layout and driver verification inside Docker — make image-cm5 succeeds; verify_cm5.py passes 21/21 for the CM5 and CM5 Lite (2026-10-05).
- **Framework baseline:** Verification of the original committed tree already reports a stale hello-component lock and a missing project test receipt. This build repair does not claim those independent framework gates pass, or claim physical CM5 or QEMU boot evidence.

### [x] SSI-010 — One image and standard build run test clean targets

- **Priority:** P1
- **Owner:** ElixirSSI component and build tooling
- **Direction:** Expose build, run, test and clean at the repository root; build one flashable image and run it in the full CM5 emulator.
- **Conclusion:** Default make currently omits the flashable image and run uses the generic virt machine. Make build the CM5 image, route run and cluster to CM5 emulation, preserve explicit virt targets, and provide Docker-hosted emulation on macOS. Preserve emulated data and cluster identity during clean.
- **Depends on:** SSI-009
- **Implementation:**
  - [x] Update component contract, Make targets, emulator Docker transport and user guide
  - [x] Test target dispatch, cleanup boundaries and image freshness
  - [x] Isolate disposable acceptance cards from interactive state, clear stale container PID/socket files, and reuse the emulator tool image when its Dockerfile is unchanged
- **Evidence:**
  - [x] Local build target and transport regression checks pass — 8 target/transport/card/clean checks and 4 existing build checks passed (2026-10-07), including isolation of acceptance resets from interactive cards.
  - [x] Docker build and full CM5 boot pass on macOS — plain make run boots the image's eMMC partitions to the Elixir shell; the guest reports Raspberry Pi Compute Module 5 Rev 1.0, and the monitor responds on localhost:8181. Ctrl-A X exits successfully. Subsequent make build reports nothing to do (2026-10-07).
  - [x] Default test suite and static image checks pass — make build and make test: 49 Elixir tests, 12 build/target checks, and 21/21 image layout/driver checks (2026-10-07).
  - [x] make test-emulator passes 10 RP1 device tests; make test-cm5 passes 29/29 on three emulated boards, including TLS membership, shared files, distributed work, service failover in 10.0 seconds, rejoin with persistent state, SSH, and RP1 USB keyboard input (2026-10-07).
- **Qualification boundary:** Docker and tracker access were restored and the start/end peer surveys completed. The first public base-image pull used an isolated empty Docker credential configuration because this noninteractive session could not unlock the macOS keychain; subsequent plain make run/test-cm5 reuse the tool image without a registry lookup. Physical CM5 validation remains SSI-002. The independent pre-existing sample audit and missing framework receipt gates were still open at this checkpoint; SSI-011 resolves their project alignment.

### [x] SSI-011 — Align project verification with the system image workflow

- **Priority:** P1
- **Owner:** ElixirSSI project configuration and verification
- **Direction:** Align Literate AI metadata and verification with the actual Make and Docker build and emulator tests.
- **Conclusion:** The inherited Python starter suite and sample audit do not describe the retained ElixirSSI implementation. Use the compact project-owned receipt contract for the real Make suite. Keep the Standard lifecycle only for the greeting example; generated-source provenance, security and admission claims do not apply to this retained implementation and are not asserted. Full adoption would quarantine and restructure the existing repository, so it is not used. The combined make verify gate adds retained source and image currency checks beyond standalone litai verify.
- **Depends on:** none
- **Implementation:**
  - [x] Align project metadata and operator documentation; refresh resolution audits; bind an executable verification suite to current source and image evidence
- **Evidence:**
  - [x] Run the declared suite and demonstrate current verification passes and changed source or failed tests cannot reuse its receipt — make verify-update on macOS/Docker passed the image build, 49 Elixir tests, 12 build/target checks, 4 receipt failure/drift checks, 21 image checks, 10 RP1 tests and 29/29 three-board CM5 acceptance checks (failover 9.7 seconds). Current source/image fingerprints and all applicable litai verify gates pass; source-intelligence and HTML observability remain explicitly unconfigured. Evidence: verification/current.json and verification/system-image.json (2026-10-07).

### [ ] SSI-012 — Ship a downloadable system image and installed cluster environment

- **Priority:** P1
- **Owner:** ElixirSSI release, installer and management experience
- **Direction:** Publish a prebuilt image and an emulator/development installer on GitHub so users can run N nodes and reach the specified UI without building the OS.
- **Conclusion:** Release policy still targets the greeting sample. Make distribution artifacts and installed multi-node UI access explicit release requirements; qualify board support separately from emulator evidence.
- **Depends on:** none
- **Implementation:**
  - [x] Specify and implement downloadable image, prebuilt emulator bundle and installer with management UI access; align release policy and asset verification
- **Evidence:**
  - [x] Install from packaged artifacts without compiling; three emulated CM5 nodes form a cluster, the offline browser renders Healthy then Down and retains all members after reload, the packaged RemoteOS client captures a 1280x800 desktop frame, the development runtime reports Elixir 1.20.4/OTP 29, and restart preserves cards. Evidence: release artifact gate and its installed-check.json; host qualification: Apple Silicon macOS/Docker.
  - [ ] Validate and publish exact release assets and checksums; physical Pi 5/CM5 boot remains unqualified under SSI-002.

### [x] SSI-013 — Verify inter-node IPC and BEAM process distribution

- **Priority:** P1
- **Owner:** ElixirSSI cluster and scheduler
- **Direction:** Verify networking, fault tolerance and load distribution at the Elixir lightweight-process level.
- **Conclusion:** Trace native TLS BEAM distribution, task placement and service recovery; distinguish workload dispatch from automatic migration of arbitrary live processes and record fault-tolerance limits.
- **Depends on:** none
- **Implementation:**
  - [x] Audit transport, load sampling, task scheduling, service ownership and checkpoint recovery
- **Evidence:**
  - [x] Verify existing multi-node and CM5 tests and retain findings with source references — make verify-update passed 49 Elixir tests (including pmap/node loss and service migration) and 29/29 three-board CM5 checks, with TLS transport, work on all three nodes and checkpointed service recovery in 9.2 seconds. Source fingerprints and log identities are retained in verification/system-image.json (2026-10-08).

- **Audit findings:** Native distributed Erlang carries process messages, GenServer calls, task supervision, monitors and RPC over mutually verified TLS 1.3 on TCP 4370 (`cluster/distribution.ex`, `cluster/tls.ex`, `cluster/epmd.ex`). HMAC-authenticated UDP discovery beacons use port 45892 every two seconds (`cluster/discovery.ex`). QEMU provides Ethernet connectivity; it does not schedule SSI application work.
- **Process placement:** `load.ex` samples BEAM scheduler wall time and run queues once per second; score = utilization + queue length / online schedulers. `sched.ex` places spawn/run on the lowest score and interleaves parallel tasks across members up to one in-flight item per scheduler by default. Tasks are lightweight BEAM processes under each node's Task.Supervisor. Membership is reread at dispatch; monitored failed items are retried up to three times.
- **Service recovery:** `service.ex` places each named GenServer using rendezvous hashing or an explicit pin. On node loss a surviving owner starts a new process from application checkpoints; explicit move checkpoints/stops/starts the service. This is application-state recovery, not migration of a process heap, mailbox or instruction pointer. Service placement is not CPU-load-sensitive, and ordinary Kernel.spawn processes are not automatically distributed or recovered. The task coordinator is local to its caller and is not itself replicated.
- **Fault-tolerance boundaries:** Retried tasks can repeat side effects. State since the last checkpoint can be lost. `store.ex` uses a last-writer-wins CRDT and attempts synchronous replication to connected peers, but does not reject failed multicall results; this is not consensus-backed durability. Roster fencing is enabled by default at three members; two-member partitions favor availability and may run duplicate services. Fencing is membership-based, not lease-based, so strict instantaneous singleton guarantees are not claimed.

### [x] SSI-014 — Build from an absent output directory

- **Priority:** P1
- **Owner:** ElixirSSI component and kernel build tooling
- **Direction:** Fix the fresh-checkout build failure, commit and push.
- **Conclusion:** Kernel export writes modules.tar before creating os/build. Verification creates its log directory there first and masks the defect. Make export self-contained and exercise the real export script against an absent output directory.
- **Depends on:** none
- **Implementation:**
  - [x] Create the export directory before writing artifacts and specify fresh-checkout behavior
  - [x] Add a regression that executes the kernel export script with real filesystem operations
- **Evidence:**
  - [x] Regression fails before the fix and passes after it — KernelExportTests reproduces the missing modules.tar parent on the original script; passes after directory creation. Eight target tests, four verification-runner tests and two installer tests also pass.
  - [x] Plain make build succeeds from absent os/build on macOS Docker — Apple Make completed the kernel export, runtime, initramfs and CM5 image (2026-10-08).
  - [x] Complete full project verification — the original kernel export fix passes the full suite after the independent Docker Desktop mount repair in SSI-015. Fresh receipts are in verification/current.json and verification/system-image.json (2026-10-08).

### [x] SSI-015 — Keep Docker Desktop emulator state on Linux volumes

- **Priority:** P1
- **Owner:** ElixirSSI build and emulator tooling
- **Direction:** Fix the Docker Desktop blocker for supported macOS and Windows configurations.
- **Conclusion:** Nested emulator and card volumes beneath the host source bind can resolve to the host filesystem on Docker Desktop. Mount Linux state independently, route all consumers through explicit paths, and verify the actual filesystem before preparing sources or cards.
- **Depends on:** none
- **Implementation:**
  - [x] Use independent emulator and card mounts with explicit paths throughout build and acceptance — retain volume names, guard mounts before writes, route boot helpers and test cards, and auto-select Docker on Windows/WSL2.
  - [x] Cover Docker Desktop transport and path routing with regressions and document supported host invocation.
- **Evidence:**
  - [x] Regression tests exercise independent mounts and test-card isolation — 13 target checks include both Docker paths, missing-mount rejection before cleanup, boot-helper routing, card isolation and simulated WSL2 detection.
  - [x] Build and full verification succeed on macOS Docker Desktop; report Windows qualification accurately — make verify-update passed all four stages: 49 Elixir tests, 18 build/target checks, 27 image checks, 10 RP1 tests and 29/29 three-board CM5 checks (service failover 9.3 seconds). Both /emulator and /cards were confirmed on Linux ext4. Current source and image identities are bound in verification/system-image.json and verification/current.json. Source-intelligence and HTML-observability remain explicitly unconfigured. Windows/WSL2 selection and transport are regression-tested; no Windows host was available for an end-to-end run (2026-10-08).

### [x] SSI-016 — Elixir command node and development workspace

- **Priority:** P1
- **Owner:** ElixirSSI command-node Component, distribution and monitor
- **Direction:** Make command and control an Elixir/Phoenix application on the command node, with an integrated development environment for Elixir users.
- **Delivered:** Supervised OTP/Phoenix workspace with authentication, durable settings and operation history, emulated instance lifecycle, physical Pi registration, process/service inspection, verified SSH console, project editing and isolated Mix jobs. Deployment includes runtime OTP dependencies and resources, validates transfers and restores the previous application set on activation failure. The guest desktop renders and accepts input in the same workspace.
- **Installation:** Packaged Elixir installer and emulator supervisor replace the installed Python manager and separate SDL/monitor entrypoints. Adoption preserves existing cards, projects and cluster identity. Fresh SSH identities derive consistently before replication converges; legacy stored keys remain valid.
- **Plan:** [Command-node architecture](../architecture/command-node.md)
- **Validation:** `make verify-update` passed all four stages: build, unit/build/image tests, 10 RP1 tests and 29 three-board CM5 checks. Unit coverage includes 18 command tests and 57 OS tests. Fresh packaged browser acceptance passed login, lifecycle, editor/tests, dependency/resource deployment, desktop input, restart persistence, physical-node registration, mobile layout and operation while the cluster is stopped. Existing-installation browser checks also exercised service migration, desktop recovery and a Hex dependency deployment. Peer survey found no open issues, reviews or other worktrees to reconcile.
- **Boundary:** Qualification ran on macOS ARM Docker Desktop. Physical boards remain a separate hardware gate; these results do not claim Windows qualification or publish a release.

### [x] SSI-017 — Merge outstanding work and publish ElixirSSI 1.1.0

- **Priority:** P1
- **Owner:** Release policy and command-node distribution
- **Direction:** Commit and push, merge all branches, and create a new release.
- **Conclusion:** Integrate the outstanding Phoenix branch through PR #4; other remote branch tips are already ancestors of main. Cut a minor release with matching OS and command-app versions and all required downloadable assets. Hosted CI is not configured. The user explicitly authorized the existing verified project and packaged-install gates for this release.
- **Depends on:** none
- **Implementation:**
  - [x] Merge all outstanding branch work and declare command-app version mirroring
  - [x] Prepare and qualify through litai release, then publish the checked version 1.1.0 assets
- **Evidence:**
  - [x] Verify exact prepared revision, packaged three-node browser acceptance and uploaded release assets

- **Outcome:** [ElixirSSI 1.1.0](https://github.com/jordanhubbard/ElixirSSI/releases/tag/v1.1.0) is published at `766727ba9636aea25cf5ab33ae6dbfb2c1b43c6a`. All 12 assets passed full download, size and SHA-256 verification through `litai release verify-published`. The existing three-node installation was restored. The publisher’s fixed 120-second upload timeout required completing the unchanged qualified assets with `gh`; the tag was not moved. Main advances to 1.2.0 for development.
