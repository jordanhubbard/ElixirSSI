# ElixirSSI

**An operating system built from the Erlang BEAM, with Elixir as the system
language, that turns any number of Raspberry Pi Compute Module 5 boards into
one machine.**

Flash the same image to every CM5, plug them into a switch, and they form a
single system image: one shell that sees every machine's processes, one
filesystem tree across their disks, a scheduler that spreads work over all
their cores, services that move when a machine dies — and a remote desktop,
drawn by whichever Pi is alive, on your workstation through
[RemoteOS-SDL](https://github.com/jordanhubbard/RemoteOS-SDL).

```text
ssi-550001(2)> nodes
HOST        ADDRESS        CORES  MEMORY  LOAD  PROCS  TEMP  MODEL
ssi-550002  169.254.142.2  4      2.0G    0%    103    -     linux,dummy-virt
ssi-550003  169.254.150.3  4      2.0G    0%    103    -     linux,dummy-virt
ssi-550001  169.254.184.1  4      2.0G    0%    103    -     linux,dummy-virt
ssi-550001(8)> pmap(1..12, fn _ -> node() end) |> Enum.frequencies()
%{"ssi@169.254.184.1": 4, "ssi@169.254.150.3": 4, "ssi@169.254.142.2": 4}
ssi-550001(4)> ps name: "SSI.Store"
PID                   NAME       REDUCTIONS  MEMORY  MSGQ  STATE
ssi-550001:<0.865.0>  SSI.Store  3542        19.0K   0     waiting
ssi-550002:<0.865.0>  SSI.Store  3195        18.4K   0     waiting
ssi-550003:<0.865.0>  SSI.Store  2936        18.4K   0     waiting
```

*(Three nodes under QEMU/KVM running the shipped CM5 kernel; on hardware
the model column shows the board, e.g. "Raspberry Pi Compute Module 5".)*

The cluster desktop, drawn on RemoteOS-SDL. Each Mandelbrot tile is outlined
in the colour of the Pi that computed it; the Shell window ran `pmap` across
both machines:

![Cluster desktop on two nodes](docs/images/desktop-before-failover.png)

The same desktop after the machine drawing it was killed: another node
restarted it within seconds, with the zoomed view and the shell's history
restored, and the menu bar now reads *drawn by ssi-550002*:

![Cluster desktop after failover](docs/images/desktop-after-failover.png)

Like [PythonOS](https://github.com/jordanhubbard/pythonos) and
[RubyOS](https://github.com/jordanhubbard/RubyOS), the language runtime *is*
the operating system: the BEAM runs as PID 1 and everything above the kernel
— devices, DHCP, storage, clustering, shells, SSH, the desktop — is Elixir.
Unlike them, it runs on real CM5 hardware (Linux is used strictly as the
hardware abstraction layer), and it is a distributed system first.

| | |
| --- | --- |
| Get started | [docs/user/getting-started.md](docs/user/getting-started.md) |
| Architecture and design rationale | [docs/architecture/elixirssi.md](docs/architecture/elixirssi.md) |
| Behavioral specification | [components/elixirssi/component.md](components/elixirssi/component.md) |
| Source | [os/](os/) — `ssi/` Elixir system, `substrate/` C shim and NIF, `kernel/`, `scripts/` |
| Emulated CM5 hardware (BCM2712 + RP1 from public documentation) | [docs/architecture/cm5-emulation.md](docs/architecture/cm5-emulation.md) |
| Watching and controlling the cluster: the monitor page | [docs/user/getting-started.md#watch-the-cluster](docs/user/getting-started.md#watch-the-cluster) |
| Status and next steps | [docs/roadmap/active-work.md](docs/roadmap/active-work.md) |

```console
cd os && make && make test && make cluster N=3
```

## Release engineers

Jordan Hubbard
