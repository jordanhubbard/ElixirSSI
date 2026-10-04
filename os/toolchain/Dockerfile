# ElixirSSI builder: Erlang/OTP and Elixir built from pinned upstream source on
# musl/aarch64. The resulting /opt/erlang tree is copied verbatim into the
# initramfs, so the guest runs exactly the runtime that compiled the system.
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache build-base autoconf perl ncurses-dev openssl-dev \
      zlib-dev linux-headers bash git make cpio xz gzip coreutils findutils \
      e2fsprogs e2fsprogs-extra dosfstools mtools sfdisk file binutils

ARG OTP_VERSION
ARG OTP_SHA256
ARG ELIXIR_VERSION
ARG ELIXIR_SHA256
COPY otp_src_${OTP_VERSION}.tar.gz elixir-${ELIXIR_VERSION}.tar.gz /src/

RUN cd /src && echo "${OTP_SHA256}  otp_src_${OTP_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf otp_src_${OTP_VERSION}.tar.gz && cd otp_src_${OTP_VERSION} \
 && ./configure --prefix=/opt/erlang \
      --without-javac --without-wx --without-odbc --without-debugger \
      --without-observer --without-et --without-megaco --without-jinterface \
      --without-cosNotification --without-diameter --without-reltool \
      --enable-builtin-zlib \
      --with-ssl \
 && for app in crypto ssh ssl public_key; do test ! -e lib/$app/SKIP || { cat lib/$app/SKIP; exit 1; }; done \
 && make -j"$(nproc)" && make install \
 && cd / && rm -rf /src/otp_src_${OTP_VERSION}

ENV PATH=/opt/erlang/bin:$PATH LANG=C.UTF-8
RUN cd /src && echo "${ELIXIR_SHA256}  elixir-${ELIXIR_VERSION}.tar.gz" | sha256sum -c - \
 && tar xzf elixir-${ELIXIR_VERSION}.tar.gz && cd elixir-${ELIXIR_VERSION} \
 && make -j"$(nproc)" compile && make PREFIX=/opt/elixir install \
 && cd / && rm -rf /src
ENV PATH=/opt/elixir/bin:/opt/erlang/bin:$PATH MIX_HOME=/opt/mix HEX_OFFLINE=1
# Image-assembly tools, kept in a late layer so adding one does not rebuild OTP.
RUN apk add --no-cache zstd ncurses-terminfo
WORKDIR /work
