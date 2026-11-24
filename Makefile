# Unified Makefile for KryX Linux (`kryx-linux/iso`)
# Builds BOTH:
#   1. OCI Container & Base RootFS (`make container-rootfs`, `make docker`, `make verify-image`)
#   2. Hybrid BIOS + UEFI GRUB Live ISO (`make all`, `make kernel`, `make rootfs`, `make initramfs`, `make iso`, `make verify-iso`)
# Powered strictly by `kpm`, CRUX ISO's `linux-6.18.63` kernel, and GRUB.

# --- Shared build configuration ---
CRUX_VERSION    ?= 3.8
BUILD_DIR       ?= build
WORK_DIR        ?= $(BUILD_DIR)/work
BIN_DIR         ?= $(BUILD_DIR)/bin
LOCAL_PKGS      ?= $(BUILD_DIR)/local-pkgs

# --- Static Go tools (kpm with integrated ports, kpm-index, kryx-src) ---
KPM_SRC         ?=
KPM_REPO        ?= https://github.com/kryx-linux/kpm.git
KPM_REF         ?= main
KPM_VERSION     ?=

KPM_BIN         ?= $(if $(wildcard $(BIN_DIR)/kpm),$(BIN_DIR)/kpm,$(shell command -v kpm 2>/dev/null || echo /usr/bin/kpm))

# --- Base container / RootFS tarball settings ---
CRUX_ISO_URL    ?= https://git.crux.nu/system/iso/releases/download/$(CRUX_VERSION)-updated/crux-$(CRUX_VERSION)-updated.iso
CRUX_ISO_PATH   ?=
CRUX_ISO_SHA256 ?=
PKG_DIR         ?=
FULL_CORE       ?= 0
INCLUDE_OPT     ?=
CORE_PORTS_SRC  ?=
CORE_PORTS_REPO ?= https://github.com/kryx-linux/core.git
CORE_PORTS_REF  ?= main
CONTAINER_ROOT  ?= $(BUILD_DIR)/container-rootfs
ROOTFS_TARBALL  ?= $(BUILD_DIR)/kryx-rootfs.tar.xz
IMAGE_NAME      ?= ghcr.io/kryx-linux/iso
IMAGE_TAG       ?= latest
BUILD_DATE      ?= $(shell date -u +'%Y-%m-%dT%H:%M:%SZ')
VCS_REF         ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)

# --- Live ISO + KryX Kernel (adopted from CRUX config, built fresh with KryX CC brand) ---
ISO_OUT           ?= kryx-linux-x86_64.iso
KERNEL_SOURCE     ?= crux-iso
KERNEL_VERSION    ?= 6.18.63
KERNEL_MIRROR     ?= https://cdn.kernel.org
KRYX_LOCALVERSION ?= -kryx
KRYX_HOSTNAME     ?= kryx
KRYX_CC_BRAND     ?= KryX-x86_64
KBUILD_BUILD_USER ?= builder
KBUILD_BUILD_HOST ?= kryx
KERNEL_JOBS       ?= $(shell nproc 2>/dev/null || echo 2)
KERNEL_SRC_TAR  ?=
KERNEL_PKG      ?= kernel
KERNEL_TAR      ?=
KERNEL_DIR      ?=
BUSYBOX_BIN     ?=
SQUASHFS_COMP   ?= zstd
INITRD_COMP     ?= gzip
VERIFY_SIG      ?= 0
SKIP_SYNC       ?= 0
PORTS_DIR       ?= /usr/ports

# --- QEMU test defaults ---
QEMU_MEM        ?= 2048
QEMU_CPUS       ?= 2
OVMF_CODE       ?= $(firstword $(wildcard /usr/share/edk2/ovmf/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd))

# --- Composed script flags ---
KPM_FLAGS := --out "$(BIN_DIR)" --repo "$(KPM_REPO)" --ref "$(KPM_REF)"
ifneq ($(strip $(KPM_SRC)),)
KPM_FLAGS += --src "$(KPM_SRC)"
endif
ifneq ($(strip $(KPM_VERSION)),)
KPM_FLAGS += --version "$(KPM_VERSION)"
endif

EXTRACT_FLAGS := --output "$(CONTAINER_ROOT)" --work-dir "$(WORK_DIR)" --kpm-bin "$(BIN_DIR)/kpm" --save-pkgs "$(LOCAL_PKGS)"
ifneq ($(strip $(CRUX_ISO_PATH)),)
EXTRACT_FLAGS += --iso "$(CRUX_ISO_PATH)"
else ifneq ($(strip $(PKG_DIR)),)
EXTRACT_FLAGS += --pkg-dir "$(PKG_DIR)"
else
EXTRACT_FLAGS += --iso-url "$(CRUX_ISO_URL)"
endif
ifneq ($(strip $(CRUX_ISO_SHA256)),)
EXTRACT_FLAGS += --iso-sha256 "$(CRUX_ISO_SHA256)"
endif
ifeq ($(FULL_CORE),1)
EXTRACT_FLAGS += --full-core
else
EXTRACT_FLAGS += --exclude-file "config/core-exclude.txt"
endif
ifneq ($(strip $(INCLUDE_OPT)),)
EXTRACT_FLAGS += --include-opt "$(INCLUDE_OPT)"
endif

CUSTOMIZE_FLAGS := --rootfs "$(CONTAINER_ROOT)" --kpm-bin "$(BIN_DIR)/kpm" --kpm-index-bin "$(BIN_DIR)/kpm-index" --kpm-ini "config/kpm.ini" --tarball "$(ROOTFS_TARBALL)"
ifneq ($(strip $(CORE_PORTS_SRC)),)
CUSTOMIZE_FLAGS += --ports-core-dir "$(CORE_PORTS_SRC)"
else
CUSTOMIZE_FLAGS += --ports-core-repo "$(CORE_PORTS_REPO)" --ports-core-ref "$(CORE_PORTS_REF)"
endif

KERNEL_FLAGS := --version "$(KERNEL_VERSION)" --mirror "$(KERNEL_MIRROR)" --localversion "$(KRYX_LOCALVERSION)" --hostname "$(KRYX_HOSTNAME)" --cc-brand "$(KRYX_CC_BRAND)" --build-user "$(KBUILD_BUILD_USER)" --build-host "$(KBUILD_BUILD_HOST)" --build-dir "$(BUILD_DIR)" --jobs "$(KERNEL_JOBS)"
ifneq ($(strip $(KERNEL_SRC_TAR)),)
KERNEL_FLAGS += --src-tar "$(KERNEL_SRC_TAR)"
endif

ROOTFS_FLAGS := --build-dir "$(BUILD_DIR)" --kpm-bin "$(KPM_BIN)" --comp "$(SQUASHFS_COMP)"
ifneq ($(strip $(LOCAL_PKGS)),)
ifneq ($(wildcard $(LOCAL_PKGS)),)
ROOTFS_FLAGS += --local-pkgs "$(LOCAL_PKGS)"
endif
endif
ifneq ($(strip $(KERNEL_DIR)),)
ROOTFS_FLAGS += --kernel-dir "$(KERNEL_DIR)"
BUILD_CRUX_KERNEL := 0
else ifneq ($(strip $(KERNEL_TAR)),)
ROOTFS_FLAGS += --kernel-tar "$(KERNEL_TAR)"
BUILD_CRUX_KERNEL := 0
else ifeq ($(KERNEL_SOURCE),crux-iso)
ROOTFS_FLAGS += --kernel-dir "$(BUILD_DIR)/kernel-stage"
BUILD_CRUX_KERNEL := 1
else
ROOTFS_FLAGS += --kernel-pkg "$(KERNEL_PKG)"
BUILD_CRUX_KERNEL := 0
endif
ifeq ($(VERIFY_SIG),1)
ROOTFS_FLAGS += --verify
endif
ifeq ($(SKIP_SYNC),1)
ROOTFS_FLAGS += --no-sync
endif

INITRD_FLAGS := --build-dir "$(BUILD_DIR)" --comp "$(INITRD_COMP)"
ifneq ($(strip $(BUSYBOX_BIN)),)
INITRD_FLAGS += --busybox "$(BUSYBOX_BIN)"
endif

.PHONY: help all all-container kpm container-rootfs docker verify-image \
        kernel kernel-clean kernel-distclean essential-pkgs rootfs initramfs iso verify-iso \
        lint qemu qemu-uefi qemu-serial clean

help:
	@echo "KryX Linux Unified Base Image & Live ISO Builder (kryx-linux/iso)"
	@echo ""
	@echo "Live ISO Targets:"
	@echo "  make all               Build CRUX ISO kernel, live rootfs, initramfs, and $(ISO_OUT)"
	@echo "  make kernel            Download & compile CRUX's ISO kernel (linux-$(KERNEL_VERSION))"
	@echo "  make essential-pkgs    Ensure every core & essential package in packages.live is built"
	@echo "  make rootfs            Build minimal live rootfs via kpm and pack live/rootfs.squashfs"
	@echo "  make initramfs         Generate initrd.img (busybox + storage/live modules + /init)"
	@echo "  make iso               Create $(ISO_OUT) using GRUB (grub-mkrescue / xorriso)"
	@echo "  make verify-iso        Validate ISO El Torito boot records & SquashFS contents"
	@echo ""
	@echo "Container / RootFS Targets:"
	@echo "  make kpm               Build static kpm (with integrated ports), kpm-index, and kryx-src"
	@echo "  make container-rootfs  Extract & customize KryX base rootfs tarball ($(ROOTFS_TARBALL))"
	@echo "  make docker            Build OCI container image ($(IMAGE_NAME):$(IMAGE_TAG))"
	@echo "  make verify-image      Run container verification suite against $(IMAGE_NAME):$(IMAGE_TAG)"
	@echo "  make all-container     Build kpm + container-rootfs + docker + verify-image"
	@echo ""
	@echo "Utility & Test Targets:"
	@echo "  make lint              Validate shell syntax across all scripts, bin/, initramfs/, config/"
	@echo "  make qemu              Boot $(ISO_OUT) in QEMU (BIOS)"
	@echo "  make qemu-uefi         Boot $(ISO_OUT) in QEMU (UEFI via OVMF)"
	@echo "  make qemu-serial       Boot $(ISO_OUT) in headless QEMU serial console"
	@echo "  make clean             Remove $(BUILD_DIR)/ and $(ISO_OUT)"

ifeq ($(BUILD_CRUX_KERNEL),1)
all: kernel rootfs initramfs iso
else
all: rootfs initramfs iso
endif

all-container: container-rootfs docker verify-image

kpm:
	./scripts/build-kpm.sh $(KPM_FLAGS)

container-rootfs: kpm
	./scripts/extract-rootfs.sh $(EXTRACT_FLAGS)
	./scripts/customize-rootfs.sh $(CUSTOMIZE_FLAGS)

$(ROOTFS_TARBALL): container-rootfs

docker: $(ROOTFS_TARBALL)
	docker build \
		--build-arg ROOTFS_TARBALL="$(ROOTFS_TARBALL)" \
		--build-arg CRUX_VERSION="$(CRUX_VERSION)" \
		--build-arg BUILD_DATE="$(BUILD_DATE)" \
		--build-arg VCS_REF="$(VCS_REF)" \
		-t "$(IMAGE_NAME):$(IMAGE_TAG)" \
		.

verify-image:
	./scripts/verify-image.sh "$(IMAGE_NAME):$(IMAGE_TAG)"

kernel:
	./scripts/mkkernel.sh $(KERNEL_FLAGS)

kernel-clean:
	rm -rf "$(BUILD_DIR)/kernel-stage" "$(BUILD_DIR)/kernel-src/linux-$(KERNEL_VERSION)"

kernel-distclean: kernel-clean
	rm -rf "$(BUILD_DIR)/kernel-src"

essential-pkgs:
	./scripts/build-essential-pkgs.sh --ports-dir "$(PORTS_DIR)" --out-dir "$(LOCAL_PKGS)" --kpm-bin "$(KPM_BIN)"

rootfs:
	./scripts/mkrootfs.sh $(ROOTFS_FLAGS)

initramfs:
	./scripts/mkinitramfs.sh $(INITRD_FLAGS)

iso:
	./scripts/mkiso.sh --build-dir "$(BUILD_DIR)" --out "$(ISO_OUT)"

verify-iso:
	./scripts/verify-iso.sh "$(ISO_OUT)"

lint:
	bash -n \
		scripts/build-kpm.sh \
		scripts/extract-rootfs.sh \
		scripts/customize-rootfs.sh \
		scripts/verify-image.sh \
		scripts/build-essential-pkgs.sh \
		scripts/mkkernel.sh \
		scripts/mkrootfs.sh \
		scripts/mkinitramfs.sh \
		scripts/mkiso.sh \
		scripts/verify-iso.sh \
		bin/setup \
		bin/setup-chroot
	sh -n initramfs/init config/rc config/rc.shutdown

qemu:
	qemu-system-x86_64 -enable-kvm -m $(QEMU_MEM) -smp $(QEMU_CPUS) -cdrom "$(ISO_OUT)" -boot d

qemu-uefi:
	@test -n "$(OVMF_CODE)" || { echo "ERROR: OVMF firmware not found (install edk2-ovmf / ovmf)" >&2; exit 1; }
	qemu-system-x86_64 -enable-kvm -m $(QEMU_MEM) -smp $(QEMU_CPUS) -bios "$(OVMF_CODE)" -cdrom "$(ISO_OUT)" -boot d

qemu-serial:
	qemu-system-x86_64 -enable-kvm -m $(QEMU_MEM) -smp $(QEMU_CPUS) -cdrom "$(ISO_OUT)" -boot d -nographic

clean:
	rm -rf "$(BUILD_DIR)" "$(ISO_OUT)" "$(ISO_OUT).sha256"
