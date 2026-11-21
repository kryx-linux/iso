# Makefile for building the crux-rolling CRUX Linux base Docker image

CRUX_VERSION    ?= 3.8
ISO_URL         ?= https://git.crux.nu/system/iso/releases/download/$(CRUX_VERSION)-updated/crux-$(CRUX_VERSION)-updated.iso
ISO_PATH        ?=
ISO_SHA256      ?=
PKG_DIR         ?=
FULL_CORE       ?= 0
INCLUDE_OPT     ?=

PE_SRC          ?=
PE_REPO         ?= https://github.com/crux-rolling/pe.git
PE_REF          ?= main
PE_VERSION      ?=

CORE_PORTS_SRC  ?=
CORE_PORTS_REPO ?= https://git.crux.nu/ports/core.git
CORE_PORTS_REF  ?= $(CRUX_VERSION)

BUILD_DIR       ?= build
WORK_DIR        ?= $(BUILD_DIR)/work
BIN_DIR         ?= $(BUILD_DIR)/bin
ROOTFS_DIR      ?= $(BUILD_DIR)/rootfs
ROOTFS_TARBALL  ?= $(BUILD_DIR)/crux-rootfs.tar.xz

IMAGE_NAME      ?= ghcr.io/crux-rolling/image
IMAGE_TAG       ?= latest
BUILD_DATE      ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
VCS_REF         ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

EXTRACT_FLAGS   := --output "$(ROOTFS_DIR)" --work-dir "$(WORK_DIR)" --pe-bin "$(BIN_DIR)/pe"
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

CUSTOMIZE_FLAGS := --rootfs "$(ROOTFS_DIR)" --pe-bin "$(BIN_DIR)/pe" --pe-index-bin "$(BIN_DIR)/pe-index" --pe-ini "config/pe.ini" --tarball "$(ROOTFS_TARBALL)"
ifneq ($(strip $(CORE_PORTS_SRC)),)
CUSTOMIZE_FLAGS += --ports-core-dir "$(CORE_PORTS_SRC)"
else
CUSTOMIZE_FLAGS += --ports-core-repo "$(CORE_PORTS_REPO)" --ports-core-ref "$(CORE_PORTS_REF)"
endif

PE_FLAGS        := --out "$(BIN_DIR)" --repo "$(PE_REPO)" --ref "$(PE_REF)"
ifneq ($(strip $(PE_SRC)),)
PE_FLAGS        += --src "$(PE_SRC)"
endif
ifneq ($(strip $(PE_VERSION)),)
PE_FLAGS        += --version "$(PE_VERSION)"
endif

.PHONY: help pe rootfs docker verify lint clean

help:
	@echo "CRUX Rolling Base Image Build Targets:"
	@echo "  make pe        Build static pe and pe-index binaries"
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
	@echo "  PE_SRC=../pe                    Build pe from a local checkout"
	@echo "  CORE_PORTS_SRC=../core          Copy /usr/ports/core from a local checkout"

pe:
	./scripts/build-pe.sh $(PE_FLAGS)

rootfs: pe
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
	bash -n scripts/build-pe.sh scripts/extract-rootfs.sh scripts/customize-rootfs.sh scripts/verify-image.sh

clean:
	rm -rf "$(BUILD_DIR)"
