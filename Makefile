# ElixirSSI: everything is built from os/. See os/Makefile or `make help`.
TARGETS := all build help test-unit test-build run run-virt cluster cluster-virt \
	test-cluster test-desktop image-cm5 emulator run-cm5 cluster-cm5 \
	test-emulator test-cm5 test-monitor clean
.PHONY: $(TARGETS)
$(TARGETS):
	$(MAKE) -C os $@

# Full project verification includes retained source and built image currency.
.PHONY: test verify verify-update test-verification
test: test-verification
	$(MAKE) -C os test
test-verification:
	python3 scripts/test-verification.py
verify:
	python3 scripts/verify-project.py
verify-update:
	python3 scripts/verify-project.py --update
