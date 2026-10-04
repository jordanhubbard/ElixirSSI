# ElixirSSI project goals

This is the durable goals record; `docs/` is subordinate to it.

1. **A real operating system made of a language runtime.** The Erlang BEAM is
   the system runtime and Elixir the system programming language, following
   PythonOS and RubyOS. Native code is limited to the PID-1 shim and one NIF of
   policy-free system calls; Linux is the hardware abstraction layer only.
2. **Native on the Raspberry Pi Compute Module 5.** The shipped kernel and
   image boot the CM5 (and CM5 Lite) directly; QEMU/KVM runs the identical
   kernel and initramfs for development and automated verification.
3. **Single system image across any number of CM5s.** Machines on one
   network join automatically and present one membership, process table,
   filesystem namespace, scheduler, and set of failover services. Assume fast
   dedicated networking between nodes.
4. **Computer-scientist users.** The shell is Elixir with system commands;
   SSH reaches the same system from any node.
5. **A compelling remote desktop.** The cluster desktop speaks RemoteOS
   protocol v2 to RemoteOS-SDL and itself survives the loss of the node
   drawing it.
