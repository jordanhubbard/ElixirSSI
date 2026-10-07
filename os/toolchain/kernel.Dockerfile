# Linux kernel tools, independent of the more expensive OTP/Elixir builder.
ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}
RUN apk add --no-cache build-base bash bc bison flex perl openssl-dev elfutils-dev \
      git coreutils findutils diffutils kmod python3 linux-headers
WORKDIR /os
