# Pinned upstream inputs. Every tarball is verified against its SHA-256 before use.
OTP_VERSION      := 29.1.1
OTP_SHA256       := 054e0143e39c780e091107fc9b345792a9c1a55f6bac1eca1c1101510fc06bf6
OTP_URL          := https://github.com/erlang/otp/releases/download/OTP-$(OTP_VERSION)/otp_src_$(OTP_VERSION).tar.gz
ELIXIR_VERSION   := 1.20.4
ELIXIR_SHA256    := 2f87be1702583ecbeee82c0ad4d6353de96463cfa0fa6e7557e05f68d90da869
ELIXIR_URL       := https://github.com/elixir-lang/elixir/archive/refs/tags/v$(ELIXIR_VERSION).tar.gz
ALPINE_VERSION   := 3.22
LINUX_BRANCH     := rpi-6.18.y
LINUX_URL        := https://github.com/raspberrypi/linux
