# MUSLBOX top-level build orchestrator.
# Reproducible: every upstream artifact is pinned by URL + SHA256 in
# scripts/fetch-deps.sh.  JOBS follows the host CPU count (2 on this EC2).

JOBS       ?= $(shell nproc 2>/dev/null || echo 1)
ROOT       := $(CURDIR)
CACHE      := $(ROOT)/cache
BUILD      := $(ROOT)/build
DISTRO     := $(ROOT)/distro
ROOTFS     := $(DISTRO)/rootfs
PACKAGES   := $(DISTRO)/packages
IMAGE      := $(DISTRO)/initramfs.cpio.gz
KERNEL     := $(DISTRO)/vmlinuz-virt

.PHONY: all deps tools busybox packages rootfs image check test \
        test-package clean env help

help:
	@printf 'MUSLBOX targets:\n'
	@printf '  all deps tools busybox packages rootfs image check test test-package clean\n'
	@printf 'JOBS=%s (override with JOBS=4 make ...)\n' '$(JOBS)'

env:
	@printf 'JOBS=%s  RAM=%s  kernel=%s\n' '$(JOBS)' \
		"$$(free -h | awk '/^Mem:/{print $$2}')" '$$(nproc)-way'

all: deps tools busybox packages rootfs image check test

deps:
	@bash scripts/fetch-deps.sh

tools:
	@bash scripts/build-tools.sh

busybox: deps
	@bash scripts/build-busybox.sh

packages: tools busybox
	@bash scripts/build-packages.sh

rootfs: packages
	@bash scripts/build-rootfs.sh

image: rootfs
	@bash scripts/build-image.sh

check: image
	@bash scripts/check-size.sh

test: image
	@python3 scripts/test-boot.py

test-package: tools
	@bash scripts/test-package.sh

clean:
	rm -rf '$(BUILD)' '$(DISTRO)'
	@printf 'clean complete (cache kept)\n'
