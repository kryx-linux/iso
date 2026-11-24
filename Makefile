# Makefile for building the kryx-linux CRUX/KryX Linux base Docker image

CRUX_VERSION    ?= 3.8
ISO_URL         ?= https://git.crux.nu/system/iso/releases/download/$(CRUX_VERSION)-updated/crux-$(CRUX_VERSION)-updated.iso
ISO_PATH        ?=
ISO_SHA256      ?=
PKG_DIR         ?=
FULL_CORE       ?= 0
INCLUDE_OPT     ?=

KPM_SRC         ?=
KPM_REPO        ?= https://github.com/kryx-linux/kpm.git
KPM_REF         ?= main
KPM_VERSION     ?=

CORE_PORTS_SRC  ?=
CORE_PORTS_REPO ?= https://git.crux.nu/ports/core.git
CORE_PORTS_REF  ?= $(CRUX_VERSION)

BUILD_DIR       ?= build
WORK_DIR        ?= $(BUILD_DIR)/work
BIN_DIR         ?= $(BUILD_DIR)/bin
ROOTFS_DIR      ?= $(BUILD_DIR)/rootfs
ROOTFS_TARBALL  ?= $(BUILD_DIR)/crux-rootfs.tar.xz

IMAGE_NAME      ?= ghcr.io/kryx-linux/image
IMAGE_TAG       ?= latest
BUILD_DATE      ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
VCS_REF         ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

EXTRACT_FLAGS   := --output "$(ROOTFS_DIR)" --work-dir "$(WORK_DIR)" --kpm-bin "$(BIN_DIR)/kpm"
ifneq ($(strip $(ISO_PATH)),)
EXTRACT_FLAGS   += --iso "$(ISO_PATH)"
else ifneq ($(strip $(PKG_DIR)),)
EXTRACT_FLAGS   += --pkg-dir "$(PKG_DIR)"
else
EXTRACT_FLAGS   += --iso-url "$(ISO_URL)"
endif
ifneq ($(strip $(ISO_SHA256)),)
EXTRACT_FLAGS   += --iso-sha256 "$(ISO_SHA256)"
endif
ifeq ($(FULL_CORE),1)
EXTRACT_FLAGS   += --full-core
else
EXTRACT_FLAGS   += --exclude-file "config/core-exclude.txt"
endif
ifneq ($(strip $(INCLUDE_OPT)),)
EXTRACT_FLAGS   += --include-opt "$(INCLUDE_OPT)"
endif

CUSTOMIZE_FLAGS := --rootfs "$(ROOTFS_DIR)" --kpm-bin "$(BIN_DIR)/kpm" --kpm-index-bin "$(BIN_DIR)/kpm-index" --kpm-ini "config/kpm.ini" --tarball "$(ROOTFS_TARBALL)"
ifneq ($(strip $(CORE_PORTS_SRC)),)
CUSTOMIZE_FLAGS += --ports-core-dir "$(CORE_PORTS_SRC)"
else
CUSTOMIZE_FLAGS += --ports-core-repo "$(CORE_PORTS_REPO)" --ports-core-ref "$(CORE_PORTS_REF)"
endif

KPM_FLAGS       := --out "$(BIN_DIR)" --repo "$(KPM_REPO)" --ref "$(KPM_REF)"
ifneq ($(strip $(KPM_SRC)),)
KPM_FLAGS       += --src "$(KPM_SRC)"
endif
ifneq ($(strip $(KPM_VERSION)),)
KPM_FLAGS       += --version "$(KPM_VERSION)"
endif

.PHONY: help kpm rootfs docker verify lint clean

help:
	@echo "CRUX/KryX Rolling Base Image Build Targets:"
	@echo "  make kpm       Build static kpm, kpm-index, and kryx-src binaries"
	@echo "  make rootfs    Extract and customize CRUX rootfs tarball ($(ROOTFS_TARBALL))"
	@echo "  make docker    Build Docker image ($(IMAGE_NAME):$(IMAGE_TAG))"
	@echo "  make verify    Run container verification suite against $(IMAGE_NAME):$(IMAGE_TAG)"
	@echo "  make lint      Check shell script syntax"
	@echo "  make clean     Remove build artifacts ($(BUILD_DIR))"
	@echo ""
	@echo "Common overrides:"
	@echo "  ISO_PATH=/path/to/crux-3.8.iso  Use a local CRUX ISO instead of downloading"
	@echo "  ISO_URL=<url>                   Override upstream CRUX ISO URL"
	@echo "  ISO_SHA256=<hex>                Verify ISO SHA-256 checksum"
	@echo "  FULL_CORE=1                     Install all CRUX core packages (ignore core-exclude.txt)"
	@echo "  KPM_SRC=../kpm                  Build kpm from a local checkout"
	@echo "  CORE_PORTS_SRC=../core          Copy /usr/ports/core from a local checkout"

kpm:
	./scripts/build-kpm.sh $(KPM_FLAGS)

rootfs: kpm
	./scripts/extract-rootfs.sh $(EXTRACT_FLAGS)
	./scripts/customize-rootfs.sh $(CUSTOMIZE_FLAGS)

docker: $(ROOTFS_TARBALL)
	docker build \
		--build-arg ROOTFS_TARBALL="$(ROOTFS_TARBALL)" \
		--build-arg CRUX_VERSION="$(CRUX_VERSION)" \
		--build-arg BUILD_DATE="$(BUILD_DATE)" \
		--build-arg VCS_REF="$(VCS_REF)" \
		-t "$(IMAGE_NAME):$(IMAGE_TAG)" \
		.

verify:
	./scripts/verify-image.sh "$(IMAGE_NAME):$(IMAGE_TAG)"

lint:
	bash -n scripts/build-kpm.sh scripts/extract-rootfs.sh scripts/customize-rootfs.sh scripts/verify-image.sh

clean:
	rm -rf "$(BUILD_DIR)"
