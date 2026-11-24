#!/usr/bin/env bash
# scripts/mkkernel.sh - Download and compile the CRUX ISO kernel (linux-6.18.63)
# directly from cdn.kernel.org using CRUX's official ISO kernel config
# (kernel/linux-<ver>.config) plus the minimal KryX live fragment
# (SquashFS + OverlayFS + EFI stub), staging vmlinuz and /lib/modules/<ver>
# into <build-dir>/kernel-stage/. Never uses prebuiltkernel.org.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_VERSION="6.18.63"
KERNEL_MIRROR="https://cdn.kernel.org"
BUILD_DIR="${REPO_ROOT}/build"
OUT_DIR=""
CONFIG_FILE=""
DEFCONFIG_FILE=""
FRAGMENT_FILE="${REPO_ROOT}/kernel/kryx-live.fragment"
USE_FRAGMENT=1
SRC_TAR=""
JOBS="$(nproc 2>/dev/null || echo 2)"
FORCE=0

usage() {
    cat <<'EOF'
Usage: scripts/mkkernel.sh [options]

Builds CRUX's ISO kernel from kernel.org sources using kernel/linux-<ver>.config
(+ kernel/kryx-live.fragment for SquashFS/OverlayFS live boot) and stages
boot/vmlinuz* + lib/modules/<ver> into <build-dir>/kernel-stage/.

Options:
  --version <ver>       Kernel version (default: 6.18.63)
  --mirror <url>        Kernel mirror base URL (default: https://cdn.kernel.org)
  --build-dir <dir>     Build workspace directory (default: build/)
  --out-dir <dir>       Kernel staging output directory (default: <build-dir>/kernel-stage)
  --config <path>       Kernel .config file (default: kernel/linux-<ver>.config)
  --fragment <path>     Live Kconfig fragment (default: kernel/kryx-live.fragment)
  --no-fragment         Build exact unmodified CRUX ISO .config without live fragment
  --src-tar <path>      Pre-downloaded linux-<ver>.tar.xz tarball
  --jobs <N>            Parallel build jobs (default: nproc)
  --force               Force rebuild even if kernel-stage already exists
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)     KERNEL_VERSION="$2"; shift 2 ;;
        --mirror)      KERNEL_MIRROR="$2"; shift 2 ;;
        --build-dir)   BUILD_DIR="$2"; shift 2 ;;
        --out-dir)     OUT_DIR="$2"; shift 2 ;;
        --config)      CONFIG_FILE="$2"; shift 2 ;;
        --fragment)    FRAGMENT_FILE="$2"; shift 2 ;;
        --no-fragment) USE_FRAGMENT=0; shift ;;
        --src-tar)     SRC_TAR="$2"; shift 2 ;;
        --jobs)        JOBS="$2"; shift 2 ;;
        --force)       FORCE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "mkkernel.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$OUT_DIR" ]]        && OUT_DIR="${BUILD_DIR}/kernel-stage"
[[ -z "$CONFIG_FILE" ]]    && CONFIG_FILE="${REPO_ROOT}/kernel/linux-${KERNEL_VERSION}.config"
[[ -z "$DEFCONFIG_FILE" ]] && DEFCONFIG_FILE="${REPO_ROOT}/kernel/linux-${KERNEL_VERSION}.defconfig"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "mkkernel.sh: error: CRUX ISO kernel config not found: ${CONFIG_FILE}" >&2
    exit 1
fi

if [[ "$FORCE" -eq 0 && -f "${OUT_DIR}/boot/vmlinuz-${KERNEL_VERSION}" && -f "${OUT_DIR}/lib/modules/${KERNEL_VERSION}/modules.dep" ]]; then
    echo "[mkkernel] Reusing staged CRUX ISO kernel ${KERNEL_VERSION} at ${OUT_DIR} (pass --force to rebuild)."
    exit 0
fi

for req in make tar xz bc bison flex gcc; do
    command -v "$req" >/dev/null 2>&1 || {
        echo "mkkernel.sh: error: required host build tool '${req}' not found in PATH" >&2
        exit 1
    }
done

mkdir -p "${BUILD_DIR}/kernel-src" "$OUT_DIR"
BUILD_ABS="$(cd "$BUILD_DIR" && pwd)"
OUT_ABS="$(cd "$OUT_DIR" && pwd)"
SRC_ROOT="${BUILD_ABS}/kernel-src"
TARBALL_NAME="linux-${KERNEL_VERSION}.tar.xz"
MAJOR_VER="${KERNEL_VERSION%%.*}"

# Locate or download linux-<ver>.tar.xz (reusing ../crux-iso/kernel if present).
if [[ -z "$SRC_TAR" ]]; then
    for cand in \
        "${SRC_ROOT}/${TARBALL_NAME}" \
        "${REPO_ROOT}/kernel/${TARBALL_NAME}" \
        "${REPO_ROOT}/../crux-iso/kernel/${TARBALL_NAME}"; do
        if [[ -f "$cand" ]]; then
            SRC_TAR="$cand"
            break
        fi
    done
fi

if [[ -z "$SRC_TAR" || ! -f "$SRC_TAR" ]]; then
    SRC_TAR="${SRC_ROOT}/${TARBALL_NAME}"
    DL_URL="${KERNEL_MIRROR%/}/pub/linux/kernel/v${MAJOR_VER}.x/${TARBALL_NAME}"
    echo "[mkkernel] Downloading ${DL_URL}..."
    command -v curl >/dev/null 2>&1 || {
        echo "mkkernel.sh: error: 'curl' is required to download kernel source" >&2
        exit 1
    }
    curl -fL --retry 3 -o "${SRC_TAR}.part" "$DL_URL"
    mv -f "${SRC_TAR}.part" "$SRC_TAR"
else
    echo "[mkkernel] Using local kernel tarball: ${SRC_TAR}"
fi

KERNEL_SRC="${SRC_ROOT}/linux-${KERNEL_VERSION}"
if [[ ! -d "$KERNEL_SRC" || "$FORCE" -eq 1 ]]; then
    echo "[mkkernel] Extracting ${TARBALL_NAME}..."
    rm -rf "$KERNEL_SRC"
    tar -C "$SRC_ROOT" -xJf "$SRC_TAR"
    # Match CRUX iso/Makefile: suppress + / -dirty suffix in kernelrelease
    sed -i -e 's,\($(Q)echo "$(KERNELVERSION)\)$$$$($(CONFIG_SHELL).*" >,\1" >,' "${KERNEL_SRC}/Makefile"
fi

echo "[mkkernel] Configuring CRUX ISO kernel ${KERNEL_VERSION} from $(basename "$CONFIG_FILE")..."
make -C "$KERNEL_SRC" mrproper
cp -f "$CONFIG_FILE" "${KERNEL_SRC}/.config"

if [[ "$USE_FRAGMENT" -eq 1 && -f "$FRAGMENT_FILE" ]]; then
    echo "[mkkernel] Merging KryX live boot fragment ($(basename "$FRAGMENT_FILE"))..."
    if [[ -x "${KERNEL_SRC}/scripts/kconfig/merge_config.sh" ]]; then
        (cd "$KERNEL_SRC" && ./scripts/kconfig/merge_config.sh -m .config "$FRAGMENT_FILE")
    else
        cat "$FRAGMENT_FILE" >> "${KERNEL_SRC}/.config"
    fi
fi

make -C "$KERNEL_SRC" olddefconfig

echo "[mkkernel] Compiling linux-${KERNEL_VERSION} (bzImage + modules, -j${JOBS})..."
make -C "$KERNEL_SRC" -j"$JOBS" bzImage modules

KREL="$(make -s -C "$KERNEL_SRC" kernelrelease)"
echo "[mkkernel] Staging kernelrelease=${KREL} into ${OUT_ABS}..."
rm -rf "${OUT_ABS:?}/boot" "${OUT_ABS:?}/lib/modules"
mkdir -p "${OUT_ABS}/boot" "${OUT_ABS}/usr/src"

install -m 0644 "${KERNEL_SRC}/arch/x86/boot/bzImage" "${OUT_ABS}/boot/vmlinuz-${KREL}"
ln -sf "vmlinuz-${KREL}" "${OUT_ABS}/boot/vmlinuz"
install -m 0644 "${KERNEL_SRC}/System.map" "${OUT_ABS}/boot/System.map-${KREL}"
install -m 0644 "${KERNEL_SRC}/.config" "${OUT_ABS}/boot/config-${KREL}"

# Include CRUX's reference ISO config & defconfig under /usr/src for target builds.
install -m 0644 "$CONFIG_FILE" "${OUT_ABS}/usr/src/linux-${KERNEL_VERSION}.config"
if [[ -f "$DEFCONFIG_FILE" ]]; then
    install -m 0644 "$DEFCONFIG_FILE" "${OUT_ABS}/usr/src/linux-${KERNEL_VERSION}.defconfig"
fi

make -C "$KERNEL_SRC" INSTALL_MOD_PATH="$OUT_ABS" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "${OUT_ABS}/lib/modules/${KREL}/build" "${OUT_ABS}/lib/modules/${KREL}/source"

ls -lh "${OUT_ABS}/boot/vmlinuz-${KREL}"
echo "[mkkernel] CRUX ISO kernel ${KREL} staged successfully at ${OUT_ABS}."
