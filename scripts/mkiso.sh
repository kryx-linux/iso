#!/usr/bin/env bash
# scripts/mkiso.sh - Assemble hybrid BIOS + UEFI bootable KryX Linux Live ISO
# using GRUB (`grub-mkrescue` / `grub2-mkrescue`) and `xorriso`.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build"
ISO_STAGE=""
OUT_ISO="${REPO_ROOT}/kryx-linux-x86_64.iso"
VOLID="KRYX_LIVE"
GRUB_CFG="${REPO_ROOT}/grub/grub.cfg"

usage() {
    cat <<'EOF'
Usage: scripts/mkiso.sh [options]

Creates a hybrid BIOS + UEFI bootable KryX Linux Live ISO using GRUB and xorriso.

Options:
  --build-dir <dir>   Build workspace directory (default: build/)
  --iso-stage <dir>   ISO staging directory (default: <build-dir>/iso)
  --out <path>        Output ISO file path (default: kryx-linux-x86_64.iso)
  --volid <label>     ISO-9660 volume ID (default: KRYX_LIVE)
  --grub-cfg <path>   Path to grub.cfg (default: grub/grub.cfg)
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --iso-stage) ISO_STAGE="$2"; shift 2 ;;
        --out)       OUT_ISO="$2"; shift 2 ;;
        --volid)     VOLID="$2"; shift 2 ;;
        --grub-cfg)  GRUB_CFG="$2"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "mkiso.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$ISO_STAGE" ]] && ISO_STAGE="${BUILD_DIR}/iso"

# Detect grub-mkrescue (Debian/CRUX/Arch) or grub2-mkrescue (Fedora/RHEL).
GRUB_MKRESCUE=""
for bin in grub-mkrescue grub2-mkrescue; do
    if command -v "$bin" >/dev/null 2>&1; then
        GRUB_MKRESCUE="$bin"
        break
    fi
done

if [[ -z "$GRUB_MKRESCUE" ]]; then
    echo "mkiso.sh: error: neither grub-mkrescue nor grub2-mkrescue found in PATH" >&2
    exit 1
fi

command -v xorriso >/dev/null 2>&1 || {
    echo "mkiso.sh: error: 'xorriso' is required by ${GRUB_MKRESCUE}" >&2
    exit 1
}

for req in "${ISO_STAGE}/boot/vmlinuz" "${ISO_STAGE}/boot/initrd.img" "${ISO_STAGE}/live/rootfs.squashfs"; do
    if [[ ! -f "$req" ]]; then
        echo "mkiso.sh: error: missing required artifact: ${req}" >&2
        echo "          Run scripts/mkrootfs.sh and scripts/mkinitramfs.sh first." >&2
        exit 1
    fi
done

# Stage GRUB config and live media marker file (/kryx-media).
mkdir -p "${ISO_STAGE}/boot/grub"
install -m 0644 "$GRUB_CFG" "${ISO_STAGE}/boot/grub/grub.cfg"
printf 'KryX Linux Live (x86_64) built %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > "${ISO_STAGE}/kryx-media"

mkdir -p "$(dirname "$OUT_ISO")"
rm -f "$OUT_ISO"

echo "[mkiso] Building hybrid BIOS + UEFI ISO via ${GRUB_MKRESCUE} -> ${OUT_ISO}..."
"$GRUB_MKRESCUE" \
    -o "$OUT_ISO" \
    "$ISO_STAGE" \
    -- \
    -volid "$VOLID"

sha256sum "$OUT_ISO" > "${OUT_ISO}.sha256"
echo "[mkiso] Built:"
ls -lh "$OUT_ISO"
cat "${OUT_ISO}.sha256"
