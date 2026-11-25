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
    squashfs-root/bin/sh \
    squashfs-root/bin/login \
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

# Audit shared library dependencies of critical live binaries using readelf.
if command -v readelf >/dev/null 2>&1; then
    echo "[verify-iso] Auditing shared library dependencies of critical live binaries..."
    unsquashfs -f -d "${TMP_DIR}/sfs" "${TMP_DIR}/rootfs.squashfs" >/dev/null
    MISSING_LIBS=0
    for rel_bin in \
        sbin/init \
        sbin/agetty \
        bin/sh \
        bin/bash \
        bin/login \
        usr/bin/passwd \
        sbin/ip \
        sbin/dhcpcd \
        usr/bin/curl \
        usr/bin/gawk \
        usr/sbin/dbus-daemon \
        usr/sbin/grub-install \
        usr/bin/grub-mkrescue; do
        bin_path="${TMP_DIR}/sfs/${rel_bin}"
        [[ -f "$bin_path" ]] || continue
        while IFS= read -r needed; do
            [[ -z "$needed" ]] && continue
            found=0
            for ldir in lib lib64 usr/lib usr/lib64; do
                if [[ -e "${TMP_DIR}/sfs/${ldir}/${needed}" ]]; then
                    found=1
                    break
                fi
            done
            if [[ "$found" -eq 0 ]]; then
                echo "verify-iso.sh: error: /${rel_bin} requires missing shared library: ${needed}" >&2
                MISSING_LIBS=1
            fi
        done < <(readelf -d "$bin_path" 2>/dev/null | sed -n 's/.*(NEEDED).*Shared library: \[\(.*\)\]/\1/p')
    done
    if [[ "$MISSING_LIBS" -ne 0 ]]; then
        echo "verify-iso.sh: error: unresolved shared library dependencies in live rootfs" >&2
        exit 1
    fi
    echo "  [OK] All critical live binaries have satisfied shared libraries"

    # Verify initramfs busybox is baseline x86-64 (not Ubuntu amd64v3/AVX).
    if command -v cpio >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
        echo "[verify-iso] Checking initrd.img busybox ISA compatibility..."
        xorriso -osirrox on -indev "$ISO_FILE" -extract /boot/initrd.img "${TMP_DIR}/initrd.img" >/dev/null 2>&1
        mkdir -p "${TMP_DIR}/initrd"
        (cd "${TMP_DIR}/initrd" && gzip -dc "${TMP_DIR}/initrd.img" | cpio -idmu bin/busybox 2>/dev/null || true)
        if [[ -f "${TMP_DIR}/initrd/bin/busybox" ]]; then
            BB_NOTES="$(readelf -n "${TMP_DIR}/initrd/bin/busybox" 2>/dev/null || true)"
            if printf '%s\n' "$BB_NOTES" | grep -qiE 'amd64v3|x86 ISA needed:.*x86-64-v[234]'; then
                echo "verify-iso.sh: error: initrd /bin/busybox requires x86-64-v2+ / amd64v3 (will SIGILL on baseline x86-64/QEMU)" >&2
                exit 1
            fi
            echo "  [OK] initrd /bin/busybox is baseline x86-64 compatible (no amd64v3 / x86-64-v2+ ISA needed)"
        fi
    fi
fi

echo "[verify-iso] All ISO structure & SquashFS checks passed!"
