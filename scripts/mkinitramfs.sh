#!/usr/bin/env bash
# scripts/mkinitramfs.sh - Build initrd.img for KryX Linux live ISO.
# Bundles busybox, initramfs/init, and required block/USB/NVMe/CD/squashfs/overlay
# kernel modules from the staged live rootfs (/lib/modules/<kver>).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build"
ROOTFS_DIR=""
OUT_IMG=""
BUSYBOX_BIN=""
KVER=""
INITRD_COMP="gzip"

usage() {
    cat <<'EOF'
Usage: scripts/mkinitramfs.sh [options]

Generates initrd.img capable of detecting block/optical/USB devices, loading kernel
modules, mounting live/rootfs.squashfs with an overlay/tmpfs writable layer, and
switching root cleanly.

Options:
  --build-dir <dir>   Build workspace directory (default: build/)
  --rootfs <dir>      Staged live rootfs containing /lib/modules/<kver> (default: <build-dir>/rootfs)
  --out <path>        Output initramfs path (default: <build-dir>/iso/boot/initrd.img)
  --busybox <path>    Path to busybox binary (prefers static busybox; auto-detects host/rootfs)
  --kver <version>    Explicit kernel module directory version under /lib/modules/
  --comp <algo>       Initramfs compression: gzip or zstd (default: gzip)
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --rootfs)    ROOTFS_DIR="$2"; shift 2 ;;
        --out)       OUT_IMG="$2"; shift 2 ;;
        --busybox)   BUSYBOX_BIN="$2"; shift 2 ;;
        --kver)      KVER="$2"; shift 2 ;;
        --comp)      INITRD_COMP="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "mkinitramfs.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$ROOTFS_DIR" ]] && ROOTFS_DIR="${BUILD_DIR}/rootfs"
[[ -z "$OUT_IMG" ]]    && OUT_IMG="${BUILD_DIR}/iso/boot/initrd.img"

command -v cpio >/dev/null 2>&1 || {
    echo "mkinitramfs.sh: error: 'cpio' is required" >&2
    exit 1
}

# Locate busybox binary (prefer static busybox, then rootfs, then host PATH).
if [[ -z "$BUSYBOX_BIN" ]]; then
    for cand in \
        /usr/sbin/busybox.static \
        /bin/busybox.static \
        "${ROOTFS_DIR}/bin/busybox" \
        "${ROOTFS_DIR}/usr/bin/busybox" \
        "$(command -v busybox 2>/dev/null || true)"; do
        if [[ -n "$cand" && -x "$cand" ]]; then
            BUSYBOX_BIN="$cand"
            break
        fi
    done
fi

if [[ -z "$BUSYBOX_BIN" || ! -x "$BUSYBOX_BIN" ]]; then
    echo "mkinitramfs.sh: error: busybox not found (install busybox or pass --busybox <path>)" >&2
    exit 1
fi

STAGE="${BUILD_DIR}/initramfs-stage"
rm -rf "$STAGE"
mkdir -p \
    "${STAGE}/bin" \
    "${STAGE}/sbin" \
    "${STAGE}/dev" \
    "${STAGE}/etc" \
    "${STAGE}/lib" \
    "${STAGE}/lib64" \
    "${STAGE}/mnt" \
    "${STAGE}/newroot" \
    "${STAGE}/proc" \
    "${STAGE}/run" \
    "${STAGE}/sys" \
    "${STAGE}/tmp" \
    "${STAGE}/usr/bin" \
    "${STAGE}/usr/sbin"

# Copy busybox and, if dynamically linked, its required shared libraries.
install -m 0755 "$BUSYBOX_BIN" "${STAGE}/bin/busybox"
if command -v ldd >/dev/null 2>&1; then
    LDD_OUT="$(ldd "$BUSYBOX_BIN" 2>&1 || true)"
    if ! printf '%s\n' "$LDD_OUT" | grep -qE 'not a dynamic executable|statically linked'; then
        echo "[mkinitramfs] Busybox is dynamically linked; bundling shared libraries..."
        printf '%s\n' "$LDD_OUT" | awk '/=> \// { print $3 } /^\// { print $1 }' | while read -r lib; do
            if [[ -f "$lib" ]]; then
                mkdir -p "${STAGE}$(dirname "$lib")"
                cp -L "$lib" "${STAGE}${lib}"
            fi
        done
    fi
fi

# Create essential busybox symlinks so /init works even before --install runs.
for app in sh ash mount umount switch_root mdev modprobe insmod mkdir rmdir cp mv rm ln cat echo grep awk sed sleep ls mountpoint; do
    ln -sf busybox "${STAGE}/bin/${app}"
done

# Copy kernel modules from rootfs /lib/modules/<kver> if present.
if [[ -z "$KVER" && -d "${ROOTFS_DIR}/lib/modules" ]]; then
    KVER="$(find "${ROOTFS_DIR}/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | tail -n 1 || true)"
fi

if [[ -n "$KVER" && -d "${ROOTFS_DIR}/lib/modules/${KVER}" ]]; then
    echo "[mkinitramfs] Bundling live boot kernel modules for ${KVER}..."
    MOD_SRC="${ROOTFS_DIR}/lib/modules/${KVER}"
    MOD_DST="${STAGE}/lib/modules/${KVER}"
    mkdir -p "$MOD_DST"

    # Copy module metadata files required by depmod/modprobe.
    for meta in modules.order modules.builtin modules.builtin.modinfo modules.dep modules.dep.bin modules.alias modules.alias.bin modules.symbols modules.symbols.bin; do
        [[ -f "${MOD_SRC}/${meta}" ]] && cp -a "${MOD_SRC}/${meta}" "${MOD_DST}/"
    done

    # Copy storage, bus, HID, crypto/crc, and live filesystem module trees
    # (covering CRUX ISO kernel linux-6.18.63 modules + SquashFS/OverlayFS).
    for subdir in \
        kernel/drivers/ata \
        kernel/drivers/block \
        kernel/drivers/cdrom \
        kernel/drivers/firewire \
        kernel/drivers/hid \
        kernel/drivers/hv \
        kernel/drivers/leds \
        kernel/drivers/md \
        kernel/drivers/message \
        kernel/drivers/nvme \
        kernel/drivers/pci/controller \
        kernel/drivers/scsi \
        kernel/drivers/usb/common \
        kernel/drivers/usb/core \
        kernel/drivers/usb/host \
        kernel/drivers/usb/storage \
        kernel/drivers/virtio \
        kernel/fs/ext2 \
        kernel/fs/ext4 \
        kernel/fs/fat \
        kernel/fs/isofs \
        kernel/fs/jbd2 \
        kernel/fs/mbcache.ko* \
        kernel/fs/nls \
        kernel/fs/overlayfs \
        kernel/fs/squashfs \
        kernel/lib/crc* \
        kernel/lib/lzo \
        kernel/lib/xz \
        kernel/lib/zlib* \
        kernel/lib/zstd \
        kernel/crypto; do
        for match in ${MOD_SRC}/${subdir}; do
            if [[ -e "$match" ]]; then
                rel="${match#"${MOD_SRC}/"}"
                mkdir -p "${MOD_DST}/$(dirname "$rel")"
                cp -a "$match" "${MOD_DST}/${rel}"
            fi
        done
    done

    if command -v depmod >/dev/null 2>&1; then
        depmod -b "$STAGE" "$KVER" 2>/dev/null || true
    fi
else
    echo "[mkinitramfs] Note: no /lib/modules directory found in ${ROOTFS_DIR} (assuming monolithic/built-in kernel drivers)."
fi

# Install live /init script.
install -m 0755 "${REPO_ROOT}/initramfs/init" "${STAGE}/init"

# Pack cpio initramfs archive.
mkdir -p "$(dirname "$OUT_IMG")"
OUT_ABS="$(cd "$(dirname "$OUT_IMG")" && pwd)/$(basename "$OUT_IMG")"

echo "[mkinitramfs] Packing ${OUT_ABS} (${INITRD_COMP})..."
case "$INITRD_COMP" in
    gzip)
        (cd "$STAGE" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "${OUT_ABS}.tmp")
        ;;
    zstd)
        (cd "$STAGE" && find . -print0 | cpio --null -ov --format=newc 2>/dev/null | zstd -T0 -15 -q > "${OUT_ABS}.tmp")
        ;;
    *)
        echo "mkinitramfs.sh: error: unsupported compression '${INITRD_COMP}' (expected gzip or zstd)" >&2
        exit 2
        ;;
esac

mv -f "${OUT_ABS}.tmp" "$OUT_ABS"
ls -lh "$OUT_ABS"
echo "[mkinitramfs] Done."
