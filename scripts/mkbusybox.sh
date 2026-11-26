#!/usr/bin/env bash
# scripts/mkbusybox.sh - Build a clean, statically-linked, baseline x86-64 BusyBox
# binary for KryX Linux's live initramfs inside the KryX build toolchain.
# Avoids host distro binaries (e.g. Ubuntu 26.04 amd64v3 busybox-static) that emit
# AVX/AVX2 instructions and panic with SIGILL on baseline x86_64 / QEMU qemu64 CPUs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUSYBOX_VERSION="1.37.0"
BUSYBOX_MIRROR="https://busybox.net/downloads"
BUILD_DIR="${REPO_ROOT}/build"
OUT_BIN=""
SRC_TAR=""
JOBS="$(nproc 2>/dev/null || echo 2)"
FORCE=0

usage() {
    cat <<'EOF'
Usage: scripts/mkbusybox.sh [options]

Downloads and builds a static baseline x86-64 (-march=x86-64) BusyBox binary for
the KryX Linux live initramfs.

Options:
  --version <ver>     BusyBox version (default: 1.37.0)
  --mirror <url>      BusyBox download base URL (default: https://busybox.net/downloads)
  --build-dir <dir>   Build workspace directory (default: build/)
  --out <path>        Output static busybox path (default: <build-dir>/bin/busybox)
  --src-tar <path>    Pre-downloaded busybox-<ver>.tar.bz2 tarball
  --jobs <N>          Parallel build jobs (default: nproc)
  --force             Force fresh rebuild even if output binary already exists
  -h, --help          Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)   BUSYBOX_VERSION="$2"; shift 2 ;;
        --mirror)    BUSYBOX_MIRROR="$2"; shift 2 ;;
        --build-dir) BUILD_DIR="$2"; shift 2 ;;
        --out)       OUT_BIN="$2"; shift 2 ;;
        --src-tar)   SRC_TAR="$2"; shift 2 ;;
        --jobs)      JOBS="$2"; shift 2 ;;
        --force)     FORCE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "mkbusybox.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$OUT_BIN" ]] && OUT_BIN="${BUILD_DIR}/bin/busybox"

if [[ "$FORCE" -eq 0 && -x "$OUT_BIN" ]]; then
    echo "[mkbusybox] Reusing existing static busybox at ${OUT_BIN} (pass --force to rebuild)."
    exit 0
fi

for req in make tar bzip2 gcc strip; do
    command -v "$req" >/dev/null 2>&1 || {
        echo "mkbusybox.sh: error: required build tool '${req}' not found in PATH" >&2
        exit 1
    }
done

mkdir -p "${BUILD_DIR}/busybox-src" "$(dirname "$OUT_BIN")"
BUILD_ABS="$(cd "$BUILD_DIR" && pwd)"
OUT_ABS="$(cd "$(dirname "$OUT_BIN")" && pwd)/$(basename "$OUT_BIN")"
SRC_ROOT="${BUILD_ABS}/busybox-src"
TARBALL_NAME="busybox-${BUSYBOX_VERSION}.tar.bz2"

if [[ -z "$SRC_TAR" || ! -f "$SRC_TAR" ]]; then
    SRC_TAR="${SRC_ROOT}/${TARBALL_NAME}"
    if [[ ! -f "$SRC_TAR" ]]; then
        DL_URL="${BUSYBOX_MIRROR%/}/${TARBALL_NAME}"
        DL_FALLBACK="https://sources.buildroot.net/busybox/${TARBALL_NAME}"
        echo "[mkbusybox] Downloading ${DL_URL}..."
        command -v curl >/dev/null 2>&1 || {
            echo "mkbusybox.sh: error: 'curl' is required to download BusyBox source" >&2
            exit 1
        }
        if ! curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 -o "${SRC_TAR}.part" "$DL_URL"; then
            echo "[mkbusybox] Primary download failed, trying ${DL_FALLBACK}..." >&2
            rm -f "${SRC_TAR}.part"
            curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 -o "${SRC_TAR}.part" "$DL_FALLBACK"
        fi
        mv -f "${SRC_TAR}.part" "$SRC_TAR"
    fi
fi

BB_SRC="${SRC_ROOT}/busybox-${BUSYBOX_VERSION}"
echo "[mkbusybox] Extracting ${TARBALL_NAME}..."
rm -rf "$BB_SRC"
tar -C "$SRC_ROOT" -xjf "$SRC_TAR"

echo "[mkbusybox] Configuring static baseline x86-64 BusyBox ${BUSYBOX_VERSION}..."
make -C "$BB_SRC" defconfig >/dev/null

# Configure for pure static baseline x86-64 initramfs compatibility:
#  - CONFIG_STATIC=y: zero runtime shared library dependencies inside initrd.img
#  - Disable CONFIG_TC: BusyBox 1.37.0 tc.c references CBQ macros removed in Linux >= 6.8 headers
#  - Disable SHA hardware accel: avoids AVX/SHA-NI assumptions on baseline x86-64 CPUs
#  - Disable PAM/SELinux: keeps static link clean without extra libraries
sed -i -E \
    -e 's|^# CONFIG_STATIC is not set|CONFIG_STATIC=y|' \
    -e 's|^CONFIG_TC=y|# CONFIG_TC is not set|' \
    -e 's|^CONFIG_SHA1_HWACCEL=y|# CONFIG_SHA1_HWACCEL is not set|' \
    -e 's|^CONFIG_SHA256_HWACCEL=y|# CONFIG_SHA256_HWACCEL is not set|' \
    -e 's|^CONFIG_PAM=y|# CONFIG_PAM is not set|' \
    -e 's|^CONFIG_SELINUX=y|# CONFIG_SELINUX is not set|' \
    -e 's|^CONFIG_EXTRA_CFLAGS=.*|CONFIG_EXTRA_CFLAGS="-O2 -march=x86-64 -mtune=generic -mno-avx -mno-avx2"|' \
    "${BB_SRC}/.config"

yes "" | make -C "$BB_SRC" oldconfig >/dev/null 2>&1 || true

echo "[mkbusybox] Compiling BusyBox ${BUSYBOX_VERSION} (-j${JOBS}, -march=x86-64 -mno-avx)..."
make -C "$BB_SRC" -j"$JOBS" \
    CFLAGS="-O2 -march=x86-64 -mtune=generic -mno-avx -mno-avx2" \
    busybox

install -m 0755 "${BB_SRC}/busybox" "$OUT_ABS"
strip --strip-all "$OUT_ABS" 2>/dev/null || true

# Verify static linkage and baseline x86-64 ISA requirement (glibc IFUNCs may list
# x86-64-v3 under "ISA used", which is CPUID-gated; only "ISA needed" must stay baseline).
if command -v ldd >/dev/null 2>&1; then
    LDD_OUT="$(ldd "$OUT_ABS" 2>&1 || true)"
    if ! printf '%s\n' "$LDD_OUT" | grep -qE 'not a dynamic executable|statically linked'; then
        echo "mkbusybox.sh: error: built busybox is not statically linked: ${LDD_OUT}" >&2
        exit 1
    fi
fi

if command -v readelf >/dev/null 2>&1; then
    BB_NOTES="$(readelf -n "$OUT_ABS" 2>/dev/null || true)"
    if printf '%s\n' "$BB_NOTES" | grep -qiE 'amd64v3|x86 ISA needed:.*x86-64-v[234]'; then
        echo "mkbusybox.sh: error: built busybox requires x86-64-v2+ ISA: ${BB_NOTES}" >&2
        exit 1
    fi
fi

ls -lh "$OUT_ABS"
echo "[mkbusybox] Verified static baseline x86-64 busybox at ${OUT_ABS}."
