# ElixirSSI — build, run and test the operating system.
#
#   make                 kernel + release + initramfs (everything QEMU and the CM5 boot)
#   make test            host ExUnit suite (unit + real multi-node peers)
#   make run             boot one node under QEMU/KVM with a serial console
#   make cluster N=3     boot N nodes on a shared virtual switch
#   make test-cluster    boot a 3-node cluster and verify the single system image
#   make test-desktop    cluster desktop against a headless RemoteOS-SDL service
#   make image-cm5       eMMC/SD image for Raspberry Pi Compute Module 5
#   make emulator        QEMU with an emulated CM5 (BCM2712 + RP1), see emulator/
#   make run-cm5         boot the CM5 image on one emulated CM5 board
#   make cluster-cm5 N=3 N emulated CM5 boards on one switch
#   make test-emulator   register-level tests of the emulated RP1
#   make test-cm5        the cluster acceptance test on emulated CM5 boards
#   make test-monitor    the monitor in a browser against 4 emulated CM5s (BOARD=virt: KVM)
#   make clean           remove build outputs (keeps downloads and the kernel tree)

include toolchain/versions.mk

BUILD    := build
KBUILD   := $(BUILD)/kernel
KSRC     := $(BUILD)/src/linux
IMAGE    := $(KBUILD)/arch/arm64/boot/Image
INITRD   := $(BUILD)/ssi-initramfs.cpio.gz
BUILDER  := elixirssi-builder:otp$(OTP_VERSION)-ex$(ELIXIR_VERSION)
JOBS     ?= $(shell nproc)
N        ?= 3

# The target is always arm64. On other hosts the kernel is cross-compiled and
# the builder image runs under binfmt emulation (docker --platform).
ifneq ($(shell uname -m),aarch64)
CROSS_COMPILE ?= aarch64-linux-gnu-
export CROSS_COMPILE
endif
export SSI_BUILDER := $(BUILDER)

SSI_SRC  := $(shell find ssi/lib ssi/config ssi/rel ssi/priv/monitor -type f) ssi/mix.exs substrate/ssi_init.c substrate/ssi_sys_nif.c

.PHONY: all toolchain kernel release initramfs test run cluster test-cluster test-desktop image-cm5 \
	emulator test-emulator run-cm5 cluster-cm5 test-cm5 browser test-monitor clean help

all: $(IMAGE) $(INITRD)

help:
	@sed -n '2,16p' Makefile | sed 's/^# \{0,1\}//'

# -- toolchain ---------------------------------------------------------------

$(BUILD)/dl/otp_src_$(OTP_VERSION).tar.gz:
	mkdir -p $(BUILD)/dl && curl -fsSL -o $@ $(OTP_URL)
	echo "$(OTP_SHA256)  $@" | sha256sum -c -

$(BUILD)/dl/elixir-$(ELIXIR_VERSION).tar.gz:
	mkdir -p $(BUILD)/dl && curl -fsSL -o $@ $(ELIXIR_URL)
	echo "$(ELIXIR_SHA256)  $@" | sha256sum -c -

$(BUILD)/.toolchain: toolchain/Dockerfile toolchain/versions.mk $(BUILD)/dl/otp_src_$(OTP_VERSION).tar.gz $(BUILD)/dl/elixir-$(ELIXIR_VERSION).tar.gz
	docker build --platform linux/arm64 --network host -f toolchain/Dockerfile \
	  --build-arg ALPINE_VERSION=$(ALPINE_VERSION) \
	  --build-arg OTP_VERSION=$(OTP_VERSION) --build-arg OTP_SHA256=$(OTP_SHA256) \
	  --build-arg ELIXIR_VERSION=$(ELIXIR_VERSION) --build-arg ELIXIR_SHA256=$(ELIXIR_SHA256) \
	  -t $(BUILDER) $(BUILD)/dl
	touch $@

toolchain: $(BUILD)/.toolchain

# -- kernel ------------------------------------------------------------------

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

kernel: $(IMAGE)

# -- userland: the Elixir release and initramfs -------------------------------

$(BUILD)/.release: $(BUILD)/.toolchain $(SSI_SRC) scripts/build-release.sh
	SSI_WORKDIR=. ./mixdocker.sh 'sh scripts/build-release.sh'
	touch $@

release: $(BUILD)/.release

$(INITRD): $(BUILD)/.release $(IMAGE) scripts/mkinitramfs.py
	python3 scripts/mkinitramfs.py --build $(BUILD) --out $@

initramfs: $(INITRD)

# -- tests and running ---------------------------------------------------------

test: $(BUILD)/.toolchain
	./mixdocker.sh 'epmd -daemon; MIX_ENV=test elixir --name ssi-test@127.0.0.1 -S mix test'

run: all
	scripts/ssi-qemu run

cluster: all
	scripts/ssi-qemu cluster $(N)

test-cluster: all
	python3 scripts/test_cluster.py --nodes 3

test-desktop: all
	python3 scripts/test_cluster.py --nodes 2 --desktop

image-cm5: all
	SSI_WORKDIR=. ./mixdocker.sh 'sh scripts/mkimage-cm5.sh'

# -- the emulated Compute Module 5 ---------------------------------------------

EMULATOR := $(BUILD)/emulator/current/build/qemu-system-aarch64

emulator:
	emulator/build-qemu.sh

test-emulator: emulator
	python3 emulator/tests/test_rp1.py -v

run-cm5: emulator image-cm5
	scripts/ssi-cm5 run

cluster-cm5: emulator image-cm5
	scripts/ssi-cm5 cluster $(N)

test-cm5: emulator image-cm5
	python3 scripts/test_cluster.py --board cm5 --nodes $(N)

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
	rm -rf $(BUILD)/release $(BUILD)/runtime $(BUILD)/substrate $(BUILD)/.release $(INITRD) $(BUILD)/cm5 ssi/_build ssi/priv/*.so
