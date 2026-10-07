# Build and run the pinned CM5 QEMU inside Linux on macOS.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates git patch ninja-build python3 python3-venv python3-pip \
    build-essential pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev \
    libfdt-dev zlib1g-dev mtools dosfstools e2fsprogs util-linux \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /os
