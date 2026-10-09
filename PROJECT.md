# ElixirSSI project goals

This is the durable goals record; `docs/` is subordinate to it.

1. **A real operating system made of a language runtime.** The Erlang BEAM is
   the system runtime and Elixir the system programming language, following
   PythonOS and RubyOS. Native code is limited to the PID-1 shim and one NIF of
   policy-free system calls; Linux is the hardware abstraction layer only.
2. **Native on Raspberry Pi 5 and Compute Module 5.** The shipped kernel and
   image target Raspberry Pi 5, CM5 and CM5 Lite directly; QEMU/KVM runs the identical
   kernel and initramfs for development and automated verification.
3. **Single system image across any number of CM5s.** Machines on one
   network join automatically and present one membership, process table,
   filesystem namespace, scheduler, and set of failover services. Assume fast
   dedicated networking between nodes.
4. **Computer-scientist users.** The shell is Elixir with system commands;
   SSH reaches the same system from any node.
5. **A compelling remote desktop.** The cluster desktop speaks RemoteOS
   protocol v2 to the Phoenix workspace and itself survives the loss of the node
   drawing it.

6. **Install and run without building.** GitHub releases provide the prebuilt
   flashable SSI image and an emulator/development installer. Users can start
   N emulated boards or flash N physical boards and reach the unified Phoenix
   workspace, including the cluster desktop. Release assets carry checksums
   and are tested through the installed path; hardware qualification remains
   explicitly separate from emulation.

7. **An Elixir command node and development environment.** A supervised Elixir/OTP
   application with Phoenix LiveView is the single interface for setup, operating
   physical and emulated nodes, and developing, testing, evaluating and deploying
   Elixir applications. It remains usable while the managed SSI cluster is down.
   Elixir owns application policy and orchestration; Linux, Docker, QEMU and the
   browser remain platform dependencies. No separate Python management application
   defines the installed user experience.
