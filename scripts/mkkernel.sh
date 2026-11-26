#!/usr/bin/env bash
# scripts/mkkernel.sh - Download and compile the KryX Linux kernel (adopted from CRUX's
# kernel config + KryX live fragment) directly from cdn.kernel.org with KryX's own
# compiler identity (CC_VERSION_TEXT / LINUX_COMPILER), localversion (-kryx), and
# build host (builder@kryx). Never uses prebuiltkernel.org or upstream CRUX binary caches.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_VERSION="6.18.63"
KERNEL_MIRROR="https://cdn.kernel.org"
LOCALVERSION="-kryx"
DEFAULT_HOSTNAME="kryx"
CC_BRAND="KryX-x86_64"
BUILD_USER="builder"
BUILD_HOST="kryx"
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

Builds KryX Linux's kernel from kernel.org sources adopting kernel/linux-<ver>.config
(+ kernel/kryx-live.fragment) with KryX's own CC version branding, localversion, and
build identity, staging boot/vmlinuz* + lib/modules/<krel> into <build-dir>/kernel-stage/.

Options:
  --version <ver>       Kernel version (default: 6.18.63)
  --mirror <url>        Kernel mirror base URL (default: https://cdn.kernel.org)
  --localversion <str>  CONFIG_LOCALVERSION suffix (default: -kryx)
  --hostname <str>      CONFIG_DEFAULT_HOSTNAME (default: kryx)
  --cc-brand <str>      Compiler brand in CC_VERSION_TEXT & /proc/version (default: KryX-x86_64)
  --build-user <str>    KBUILD_BUILD_USER (default: builder)
  --build-host <str>    KBUILD_BUILD_HOST (default: kryx)
  --build-dir <dir>     Build workspace directory (default: build/)
  --out-dir <dir>       Kernel staging output directory (default: <build-dir>/kernel-stage)
  --config <path>       Base kernel .config file (default: kernel/linux-<ver>.config)
  --fragment <path>     Live Kconfig fragment (default: kernel/kryx-live.fragment)
  --no-fragment         Skip merging kryx-live.fragment
  --src-tar <path>      Pre-downloaded linux-<ver>.tar.xz tarball
  --jobs <N>            Parallel build jobs (default: nproc)
  --force               Force fresh rebuild even if kernel-stage already exists
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)      KERNEL_VERSION="$2"; shift 2 ;;
        --mirror)       KERNEL_MIRROR="$2"; shift 2 ;;
        --localversion) LOCALVERSION="$2"; shift 2 ;;
        --hostname)     DEFAULT_HOSTNAME="$2"; shift 2 ;;
        --cc-brand)     CC_BRAND="$2"; shift 2 ;;
        --build-user)   BUILD_USER="$2"; shift 2 ;;
        --build-host)   BUILD_HOST="$2"; shift 2 ;;
        --build-dir)    BUILD_DIR="$2"; shift 2 ;;
        --out-dir)      OUT_DIR="$2"; shift 2 ;;
        --config)       CONFIG_FILE="$2"; shift 2 ;;
        --fragment)     FRAGMENT_FILE="$2"; shift 2 ;;
        --no-fragment)  USE_FRAGMENT=0; shift ;;
        --src-tar)      SRC_TAR="$2"; shift 2 ;;
        --jobs)         JOBS="$2"; shift 2 ;;
        --force)        FORCE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              echo "mkkernel.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$OUT_DIR" ]]        && OUT_DIR="${BUILD_DIR}/kernel-stage"
[[ -z "$CONFIG_FILE" ]]    && CONFIG_FILE="${REPO_ROOT}/kernel/linux-${KERNEL_VERSION}.config"
[[ -z "$DEFCONFIG_FILE" ]] && DEFCONFIG_FILE="${REPO_ROOT}/kernel/linux-${KERNEL_VERSION}.defconfig"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "mkkernel.sh: error: kernel config not found: ${CONFIG_FILE}" >&2
    exit 1
fi

EXPECTED_KREL="${KERNEL_VERSION}${LOCALVERSION}"
if [[ "$FORCE" -eq 0 && -f "${OUT_DIR}/boot/vmlinuz-${EXPECTED_KREL}" && -f "${OUT_DIR}/lib/modules/${EXPECTED_KREL}/modules.dep" ]]; then
    echo "[mkkernel] Reusing staged KryX kernel ${EXPECTED_KREL} at ${OUT_DIR} (pass --force to rebuild)."
    exit 0
fi

for req in make tar xz bc bison flex gcc ld; do
    command -v "$req" >/dev/null 2>&1 || {
        echo "mkkernel.sh: error: required build tool '${req}' not found in PATH" >&2
        exit 1
    }
done

mkdir -p "${BUILD_DIR}/kernel-src" "$OUT_DIR"
BUILD_ABS="$(cd "$BUILD_DIR" && pwd)"
OUT_ABS="$(cd "$OUT_DIR" && pwd)"
SRC_ROOT="${BUILD_ABS}/kernel-src"
TARBALL_NAME="linux-${KERNEL_VERSION}.tar.xz"
MAJOR_VER="${KERNEL_VERSION%%.*}"

# Build KryX-branded gcc & ld wrappers so Kbuild stamps KryX's own compiler version
# (e.g. `gcc (KryX-x86_64) 14.4.0` and `GNU ld (KryX-x86_64) 2.43.1`) into
# CONFIG_CC_VERSION_TEXT and /proc/version with zero CRUX or Ubuntu branding.
REAL_GCC="$(command -v gcc)"
REAL_LD="$(command -v ld)"
WRAP_DIR="${BUILD_ABS}/cc-wrap"
mkdir -p "$WRAP_DIR"

cat > "${WRAP_DIR}/gcc" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        --version)
            "${REAL_GCC}" "\$@" | sed -E '1s|\([^)]*\)|(${CC_BRAND})|; 1s|[[:space:]]+\([^)]*\)\$||'
            exit \$?
            ;;
    esac
done
exec "${REAL_GCC}" "\$@"
EOF

cat > "${WRAP_DIR}/ld" <<EOF
#!/bin/sh
for arg in "\$@"; do
    case "\$arg" in
        --version|-v)
            "${REAL_LD}" "\$@" | sed -E '1s|\([^)]*\)|(${CC_BRAND})|'
            exit \$?
            ;;
    esac
done
exec "${REAL_LD}" "\$@"
EOF

chmod 0755 "${WRAP_DIR}/gcc" "${WRAP_DIR}/ld"
CC_VER_LINE="$("${WRAP_DIR}/gcc" --version | sed -n '1p')"
LD_VER_LINE="$("${WRAP_DIR}/ld" --version | sed -n '1p')"
echo "[mkkernel] Toolchain identity:"
echo "  CC : ${CC_VER_LINE}"
echo "  LD : ${LD_VER_LINE}"
echo "  ID : ${BUILD_USER}@${BUILD_HOST} (localversion=${LOCALVERSION}, hostname=${DEFAULT_HOSTNAME})"

# Locate or download linux-<ver>.tar.xz
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
    DL_FALLBACK="https://mirrors.edge.kernel.org/pub/linux/kernel/v${MAJOR_VER}.x/${TARBALL_NAME}"
    echo "[mkkernel] Downloading ${DL_URL}..."
    command -v curl >/dev/null 2>&1 || {
        echo "mkkernel.sh: error: 'curl' is required to download kernel source" >&2
        exit 1
    }
    if ! curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 -o "${SRC_TAR}.part" "$DL_URL"; then
        echo "[mkkernel] Primary download failed, trying ${DL_FALLBACK}..." >&2
        rm -f "${SRC_TAR}.part"
        curl -fL --connect-timeout 20 --retry 3 --retry-delay 5 -o "${SRC_TAR}.part" "$DL_FALLBACK"
    fi
    mv -f "${SRC_TAR}.part" "$SRC_TAR"
else
    echo "[mkkernel] Using local kernel tarball: ${SRC_TAR}"
fi

KERNEL_SRC="${SRC_ROOT}/linux-${KERNEL_VERSION}"
if [[ ! -d "$KERNEL_SRC" || "$FORCE" -eq 1 ]]; then
    echo "[mkkernel] Extracting ${TARBALL_NAME}..."
    rm -rf "$KERNEL_SRC"
    tar -C "$SRC_ROOT" -xJf "$SRC_TAR"
    # Suppress trailing '+' / '-dirty' suffix in kernelrelease
    sed -i -e 's,\($(Q)echo "$(KERNELVERSION)\)$$$$($(CONFIG_SHELL).*" >,\1" >,' "${KERNEL_SRC}/Makefile"
fi

echo "[mkkernel] Configuring KryX kernel ${EXPECTED_KREL} from $(basename "$CONFIG_FILE")..."
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

# Enforce KryX localversion and default hostname (overriding any base config value).
sed -i -E \
    -e "s|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION=\"${LOCALVERSION}\"|" \
    -e "s|^CONFIG_DEFAULT_HOSTNAME=.*|CONFIG_DEFAULT_HOSTNAME=\"${DEFAULT_HOSTNAME}\"|" \
    "${KERNEL_SRC}/.config"

export KBUILD_BUILD_USER="$BUILD_USER"
export KBUILD_BUILD_HOST="$BUILD_HOST"

make -C "$KERNEL_SRC" CC="${WRAP_DIR}/gcc" LD="${WRAP_DIR}/ld" olddefconfig

echo "[mkkernel] Compiling KryX kernel ${EXPECTED_KREL} (bzImage + modules, -j${JOBS})..."
make -C "$KERNEL_SRC" CC="${WRAP_DIR}/gcc" LD="${WRAP_DIR}/ld" -j"$JOBS" bzImage modules

KREL="$(make -s -C "$KERNEL_SRC" CC="${WRAP_DIR}/gcc" LD="${WRAP_DIR}/ld" kernelrelease)"
echo "[mkkernel] Staging kernelrelease=${KREL} into ${OUT_ABS}..."
rm -rf "${OUT_ABS:?}/boot" "${OUT_ABS:?}/lib/modules"
mkdir -p "${OUT_ABS}/boot" "${OUT_ABS}/usr/src"

install -m 0644 "${KERNEL_SRC}/arch/x86/boot/bzImage" "${OUT_ABS}/boot/vmlinuz-${KREL}"
ln -sf "vmlinuz-${KREL}" "${OUT_ABS}/boot/vmlinuz"
install -m 0644 "${KERNEL_SRC}/System.map" "${OUT_ABS}/boot/System.map-${KREL}"
install -m 0644 "${KERNEL_SRC}/.config" "${OUT_ABS}/boot/config-${KREL}"

# Include KryX-branded reference config & defconfig under /usr/src.
install -m 0644 "${KERNEL_SRC}/.config" "${OUT_ABS}/usr/src/linux-${KREL}.config"
if [[ -f "$DEFCONFIG_FILE" ]]; then
    install -m 0644 "$DEFCONFIG_FILE" "${OUT_ABS}/usr/src/linux-${KERNEL_VERSION}.defconfig"
fi

make -C "$KERNEL_SRC" CC="${WRAP_DIR}/gcc" LD="${WRAP_DIR}/ld" INSTALL_MOD_PATH="$OUT_ABS" INSTALL_MOD_STRIP=1 modules_install >/dev/null
rm -f "${OUT_ABS}/lib/modules/${KREL}/build" "${OUT_ABS}/lib/modules/${KREL}/source"

# Verify zero CRUX/Ubuntu text leaked into CONFIG_CC_VERSION_TEXT.
STAMPED_CC="$(grep '^CONFIG_CC_VERSION_TEXT=' "${OUT_ABS}/boot/config-${KREL}" || true)"
echo "[mkkernel] Verified ${STAMPED_CC}"
if printf '%s\n' "$STAMPED_CC" | grep -qiE 'crux|ubuntu'; then
    echo "mkkernel.sh: error: unexpected upstream distro text in ${STAMPED_CC}" >&2
    exit 1
fi

ls -lh "${OUT_ABS}/boot/vmlinuz-${KREL}"
echo "[mkkernel] KryX kernel ${KREL} staged successfully at ${OUT_ABS}."
