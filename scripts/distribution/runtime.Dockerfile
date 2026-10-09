FROM elixirssi-builder:otp29.1.1-ex1.20.4 AS beam
RUN mkdir -p /runtime-libs && cp -L /usr/lib/libncursesw.so.6 /usr/lib/libstdc++.so.6 \
    /usr/lib/libgcc_s.so.1 /usr/lib/libcrypto.so.3 /usr/lib/libssl.so.3 /runtime-libs/
FROM elixirssi-emulator:bookworm
COPY --from=beam /opt/erlang /opt/erlang
COPY --from=beam /opt/elixir /opt/elixir
COPY --from=beam /lib/ld-musl-aarch64.so.1 /lib/ld-musl-aarch64.so.1
COPY --from=beam /runtime-libs /opt/musl/lib
RUN printf '/opt/musl/lib\n/lib\n' > /etc/ld-musl-aarch64.path
ENV PATH=/opt/elixir/bin:/opt/erlang/bin:$PATH
COPY emulator/ /os/build/emulator/current/
COPY emulator.exs /os/emulator.exs
ENV SSI_FORWARD_BIND=0.0.0.0
WORKDIR /os
RUN elixir -e 'IO.puts(System.version())'
CMD ["elixir", "/os/emulator.exs"]
