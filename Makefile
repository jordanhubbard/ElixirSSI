# ElixirSSI: everything is built from os/. See os/Makefile or `make help`.
.PHONY: all help test run cluster test-cluster test-desktop image-cm5 clean
all help test run cluster test-cluster test-desktop image-cm5 clean:
	$(MAKE) -C os $@
