#!/usr/bin/env bash
# scripts/verify-iso.sh - Verify structure, GRUB BIOS+UEFI boot records, kernel/initrd,
# and live SquashFS contents of the built kryx-linux-x86_64.iso image.
set -euo pipefail

ISO_FILE="${1:-kryx-linux-x86_64.iso}"

if [[ ! -f "$ISO_FILE" ]]; then
    echo "verify-iso.sh: error: ISO file not found: ${ISO_FILE}" >&2
    exit 1
fi

for req in xorriso unsquashfs; do
    command -v "$req" >/dev/null 2>&1 || {
        echo "verify-iso.sh: error: required tool '${req}' not found" >&2
        exit 1
    }
done

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kryx-verify-iso.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "[verify-iso] Inspecting ${ISO_FILE}..."
ls -lh "$ISO_FILE"

echo "[verify-iso] Checking ISO9660 / El Torito boot records..."
TOC="$(xorriso -indev "$ISO_FILE" -toc 2>&1)"
printf '%s\n' "$TOC" | grep -qi "El Torito" || {
    echo "verify-iso.sh: error: ISO is missing El Torito boot catalog" >&2
    exit 1
}

echo "[verify-iso] Checking required ISO root files..."
for iso_path in /kryx-media /boot/vmlinuz /boot/initrd.img /boot/grub/grub.cfg /live/rootfs.squashfs; do
    if ! xorriso -indev "$ISO_FILE" -ls "$iso_path" >/dev/null 2>&1; then
        echo "verify-iso.sh: error: required ISO entry missing: ${iso_path}" >&2
        exit 1
    fi
    echo "  [OK] ${iso_path}"
done

echo "[verify-iso] Checking SquashFS live rootfs contents..."
xorriso -osirrox on -indev "$ISO_FILE" -extract /live/rootfs.squashfs "${TMP_DIR}/rootfs.squashfs" >/dev/null 2>&1
SFS_LIST="$(unsquashfs -lc "${TMP_DIR}/rootfs.squashfs")"

for req_path in \
    squashfs-root/sbin/init \
    squashfs-root/usr/bin/kpm \
    squashfs-root/usr/bin/setup \
    squashfs-root/usr/bin/setup-chroot \
    squashfs-root/etc/kpm.ini \
    squashfs-root/etc/kpm/keys/kryx-release.pub \
    squashfs-root/etc/inittab \
    squashfs-root/etc/rc \
    squashfs-root/boot/vmlinuz; do
    if ! grep -qx "$req_path" <<< "$SFS_LIST"; then
        echo "verify-iso.sh: error: missing expected path in rootfs.squashfs: ${req_path}" >&2
        exit 1
    fi
    echo "  [OK] ${req_path#squashfs-root}"
done

echo "[verify-iso] All ISO structure & SquashFS checks passed!"
