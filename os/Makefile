# ElixirSSI — build, run and test the operating system.
#
#   make / make build    flashable CM5 image (same image for emulator and hardware)
#   make test            unit/peer tests, build regressions, image layout checks
#   make run             boot that image in the full CM5 emulator, serial console
#   make cluster N=3     boot N emulated CM5 boards on a shared virtual switch
#   make test-cluster    boot a 3-node cluster and verify the single system image
#   make test-desktop    cluster desktop against a headless RemoteOS-SDL service
#   make image-cm5       force image repack (e.g. after changing SSI_* settings)
#   make emulator        QEMU with an emulated CM5 (BCM2712 + RP1), see emulator/
#   make run-cm5         boot the CM5 image on one emulated CM5 board
#   make cluster-cm5 N=3 N emulated CM5 boards on one switch
#   make test-emulator   register-level tests of the emulated RP1
#   make test-cm5        the cluster acceptance test on emulated CM5 boards
#   make test-monitor    the monitor in a browser against 4 emulated CM5s (BOARD=virt: KVM)
#   make clean           remove image/release outputs; keep caches, VM data and secret
#   make run-virt        generic QEMU/KVM virt machine (Linux developer shortcut)
#   make test-unit       only the hosted unit and peer-BEAM tests

include toolchain/versions.mk

BUILD    := build
KBUILD   := $(BUILD)/kernel
KSRC     := $(BUILD)/src/linux
IMAGE    := $(KBUILD)/arch/arm64/boot/Image
INITRD   := $(BUILD)/ssi-initramfs.cpio.gz
CM5_IMAGE := $(BUILD)/cm5/elixirssi-cm5.img
BUILDER  := elixirssi-builder:otp$(OTP_VERSION)-ex$(ELIXIR_VERSION)
N        ?= 3
export N
KERNEL_DOCKER ?= $(if $(filter Darwin,$(shell uname -s)),1,0)
ifeq ($(KERNEL_DOCKER),1)
JOBS     ?=
else
JOBS     ?= $(shell nproc)
endif
SHA256   := $(shell command -v sha256sum >/dev/null 2>&1 && echo sha256sum || echo 'shasum -a 256')
export JOBS
.DELETE_ON_ERROR:

# The target is always arm64. On other hosts the kernel is cross-compiled and
# the builder image runs under binfmt emulation (docker --platform).
ifeq ($(KERNEL_DOCKER),0)
ifneq ($(shell uname -m),aarch64)
CROSS_COMPILE ?= aarch64-linux-gnu-
export CROSS_COMPILE
endif
endif
export SSI_BUILDER := $(BUILDER)

SSI_SRC  := $(shell find ssi/lib ssi/config ssi/rel ssi/priv/monitor -type f) ssi/mix.exs ssi/version.json substrate/ssi_init.c substrate/ssi_sys_nif.c

.PHONY: all build toolchain kernel release initramfs test test-unit test-build run run-virt cluster cluster-virt test-cluster test-desktop image-cm5 \
	emulator test-emulator run-cm5 cluster-cm5 test-cm5 browser test-monitor clean help

all: build
build: $(CM5_IMAGE)

help:
	@sed -n '2,18p' Makefile | sed 's/^# \{0,1\}//'

# -- toolchain ---------------------------------------------------------------

$(BUILD)/dl/otp_src_$(OTP_VERSION).tar.gz:
	mkdir -p $(BUILD)/dl && curl -fsSL -o $@ $(OTP_URL)
	echo "$(OTP_SHA256)  $@" | $(SHA256) -c -

$(BUILD)/dl/elixir-$(ELIXIR_VERSION).tar.gz:
	mkdir -p $(BUILD)/dl && curl -fsSL -o $@ $(ELIXIR_URL)
	echo "$(ELIXIR_SHA256)  $@" | $(SHA256) -c -

$(BUILD)/.toolchain: toolchain/Dockerfile toolchain/versions.mk $(BUILD)/dl/otp_src_$(OTP_VERSION).tar.gz $(BUILD)/dl/elixir-$(ELIXIR_VERSION).tar.gz
	docker build --platform linux/arm64 --network host -f toolchain/Dockerfile \
	  --build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
	  --build-arg OTP_VERSION=$(OTP_VERSION) --build-arg OTP_SHA256=$(OTP_SHA256) \
	  --build-arg ELIXIR_VERSION=$(ELIXIR_VERSION) --build-arg ELIXIR_SHA256=$(ELIXIR_SHA256) \
	  -t $(BUILDER) $(BUILD)/dl
	touch $@

toolchain: $(BUILD)/.toolchain

# -- kernel ------------------------------------------------------------------

ifeq ($(KERNEL_DOCKER),1)
# The Linux source tree requires a case-sensitive filesystem. Keep it and its
# intermediates on a Docker volume; export only the artifacts consumed below.
$(IMAGE): kernel/elixirssi.config toolchain/kernel.Dockerfile toolchain/versions.mk scripts/docker-kernel.sh scripts/build-kernel.sh
	ALPINE_VERSION=$(ALPINE_VERSION) LINUX_URL=$(LINUX_URL) LINUX_BRANCH=$(LINUX_BRANCH) \
	  SSI_KERNEL_JOBS=$(JOBS) sh scripts/docker-kernel.sh
else
$(KSRC)/Makefile:
	git clone --depth 1 -b $(LINUX_BRANCH) $(LINUX_URL) $(KSRC)

$(KBUILD)/.config: $(KSRC)/Makefile kernel/elixirssi.config
	mkdir -p $(KBUILD)
	$(MAKE) -C $(KSRC) O=$(abspath $(KBUILD)) ARCH=arm64 bcm2712_defconfig
	cd $(KSRC) && scripts/kconfig/merge_config.sh -m -O $(abspath $(KBUILD)) $(abspath $(KBUILD))/.config $(abspath kernel/elixirssi.config)
	$(MAKE) -C $(KSRC) O=$(abspath $(KBUILD)) ARCH=arm64 olddefconfig

$(IMAGE): $(KBUILD)/.config
	$(MAKE) -C $(KSRC) O=$(abspath $(KBUILD)) ARCH=arm64 -j$(JOBS) Image modules dtbs
	rm -rf $(BUILD)/modroot
	$(MAKE) -C $(KSRC) O=$(abspath $(KBUILD)) ARCH=arm64 INSTALL_MOD_PATH=$(abspath $(BUILD)/modroot) INSTALL_MOD_STRIP=1 modules_install
	touch $@
endif

kernel: $(IMAGE)

# -- userland: the Elixir release and initramfs -------------------------------

$(BUILD)/.release: $(BUILD)/.toolchain $(SSI_SRC) scripts/build-release.sh
	SSI_WORKDIR=. ./mixdocker.sh 'sh scripts/build-release.sh'
	touch $@

release: $(BUILD)/.release

$(INITRD): $(BUILD)/.release $(IMAGE) scripts/mkinitramfs.py
ifeq ($(KERNEL_DOCKER),1)
	SSI_WORKDIR=. ./mixdocker.sh 'sh scripts/build-initramfs.sh'
else
	python3 scripts/mkinitramfs.py --build $(BUILD) --out $@
endif

ifeq ($(KERNEL_DOCKER),1)
$(INITRD): scripts/build-initramfs.sh
endif

initramfs: $(INITRD)

# -- tests and running ---------------------------------------------------------

test-unit: $(BUILD)/.toolchain
	./mixdocker.sh 'epmd -daemon; MIX_ENV=test elixir --name ssi-test@127.0.0.1 -S mix test'

test-build: build
	python3 scripts/test_build.py -v
	python3 scripts/test_targets.py -v
	SSI_WORKDIR=. ./mixdocker.sh 'python3 scripts/verify_cm5.py'

test: test-unit test-build

run: run-cm5

cluster: cluster-cm5

run-virt: $(IMAGE) $(INITRD)
	scripts/ssi-qemu run

cluster-virt: $(IMAGE) $(INITRD)
	scripts/ssi-qemu cluster $(N)

test-cluster: $(IMAGE) $(INITRD)
	python3 scripts/test_cluster.py --nodes 3

test-desktop: $(IMAGE) $(INITRD)
	python3 scripts/test_cluster.py --nodes 2 --desktop

$(CM5_IMAGE): $(IMAGE) $(INITRD) scripts/mkimage-cm5.sh mixdocker.sh $(wildcard boot/cm5/*)
	SSI_WORKDIR=. ./mixdocker.sh 'sh scripts/mkimage-cm5.sh'

# Explicit repack retains the existing configuration-via-environment interface.
image-cm5:
	$(MAKE) -W scripts/mkimage-cm5.sh build

# -- the emulated Compute Module 5 ---------------------------------------------

EMULATOR := $(BUILD)/emulator/current/build/qemu-system-aarch64

ifeq ($(shell uname -s),Darwin)
CM5_EXEC := bash scripts/docker-emulator.sh
emulator:
	$(CM5_EXEC) build
else
CM5_EXEC :=
emulator:
	emulator/build-qemu.sh
endif

test-emulator: emulator
	$(CM5_EXEC) python3 emulator/tests/test_rp1.py -v

run-cm5: emulator build
	$(CM5_EXEC) scripts/ssi-cm5 run

cluster-cm5: emulator build
	$(CM5_EXEC) scripts/ssi-cm5 cluster $(N)

test-cm5: emulator build
	$(CM5_EXEC) python3 scripts/test_cluster.py --board cm5 --nodes $(N)

# -- the monitor in a browser ---------------------------------------------------

BOARD ?= cm5

# playwright-core (pinned by scripts/browser/package-lock.json) and the
# headless Chromium it is built for.
$(BUILD)/browser/.installed: scripts/browser/package.json scripts/browser/package-lock.json
	mkdir -p $(BUILD)/browser
	cp scripts/browser/package.json scripts/browser/package-lock.json $(BUILD)/browser/
	npm ci --prefix $(BUILD)/browser --no-audit --no-fund
	node $(BUILD)/browser/node_modules/playwright-core/cli.js install chromium-headless-shell
	touch $@

browser: $(BUILD)/browser/.installed

ifeq ($(BOARD),virt)
test-monitor: all browser
else
test-monitor: emulator image-cm5 browser
endif
	python3 scripts/test_monitor.py --board $(BOARD) --nodes 4

clean:
	rm -rf $(BUILD)/release $(BUILD)/runtime $(BUILD)/substrate $(BUILD)/.release $(INITRD) ssi/_build ssi/priv/*.so
	rm -rf $(BUILD)/cm5/boot $(BUILD)/cm5/*.img $(BUILD)/cm5/*.img.zst $(BUILD)/cm5/*.sha256 $(BUILD)/cm5/*.vfat $(BUILD)/cm5/*.ext4
