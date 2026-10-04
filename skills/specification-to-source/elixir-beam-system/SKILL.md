---
name: "elixir-beam-system"
description: "Elixir/BEAM operating-system components where the BEAM runs as PID 1. Use for Literate AI workflow tasks on ElixirSSI."
metadata:
  author: "Literate AI maintainers <literate-ai-maintainers@users.noreply.github.com>"
schema: "urn:literate-ai:schema:v1:specification-to-source-skill"
skill_id: "elixir-beam-system"
version: "0.1.0"
title: "Elixir system on the BEAM as PID 1"
stages:
  - "generate"
dependencies: []
limitations:
  - "Do not add native code beyond the PID-1 shim and the single system-call NIF; put policy in Elixir."
  - "Do not depend on Hex packages; use Erlang/OTP and the Elixir standard library only."
  - "Do not start or rely on any Linux userland program (shell, init, udev, DHCP client, epmd)."
trust: "repository-reviewed"
---
# Elixir system on the BEAM as PID 1

This project-local skill is maintained in the ElixirSSI repository (the
`author` field above is the catalog's required canonical value).

Implement system behavior as one OTP application (`os/ssi`, module prefix `SSI`)
started by an Elixir release that the static shim `os/substrate/ssi_init.c`
execs as PID 1. Write ordinary, supervised OTP: each subsystem is a
`GenServer` (or plain module) started in dependency order from
`SSI.Application`; a crash restarts the subsystem, never the machine. The BEAM
must never exit by itself — power transitions call `SSI.Power`, which stops
services and then reboot(2).

Keep native code to two files. `ssi_init.c` mounts pseudo filesystems,
attaches `/dev/console` and execs `erlexec` with the release's boot script,
config and `vm.args`. `ssi_sys_nif.c` wraps system calls with no portable
BEAM API, one function each, with no policy; blocking calls use dirty I/O
schedulers. Every NIF has an Elixir stub that returns a dynamically typed
`{:error, :hosted}` so the same code runs hosted for tests.

Support two modes selected by `config :ssi, mode:` — `:target` (PID 1 on
ElixirSSI) and `:hosted` (tests, development). Hardware actions are taken only
in target mode; distributed behavior must run identically in both, so it can be
tested with real peer BEAMs (`:peer`) on a workstation.

For anything replicated, prefer convergent state over coordination: last-writer-wins
maps with hybrid logical clocks, anti-entropy repair, rendezvous hashing for
placement, and leaderless ownership functions every node evaluates
identically. Remote calls use `:erpc` with explicit timeouts; casts to a named
server on every node use `GenServer.abcast/3`. Values sent between nodes must
be produced by code present on every node (same release); closures defined in
test files are not.

Decode untrusted binaries only after authentication, with
`:erlang.binary_to_term(bin, [:safe])`; carry node names as strings and create
atoms only after verification. Never walk `/sys` recursively — sysfs links
loop; enumerate `/sys/bus/*/devices` and `/sys/class/*` instead.

Shell commands live in `SSI.Shell`, are imported into IEx through the
generated `.iex.exs`, print with `IO.write` (so they work on the console, over
SSH and in the desktop shell) and return
`:"do not show this result in output"` when they only print.

Verify at three levels and keep each runnable from `os/Makefile`: ExUnit unit
and peer-cluster tests (`make test`), the shipped kernel and initramfs under
QEMU/KVM driven through serial consoles that are continuously drained
(`make test-cluster`, `make test-desktop`), and static checks of the hardware
image (`scripts/verify_cm5.py`).
