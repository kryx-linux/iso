#!/usr/bin/env bash
# scripts/mkrootfs.sh - Build the minimal KryX Linux live rootfs strictly via `kpm`,
# install the CRUX ISO kernel (or custom kernel from local dir/tarball/kpm package —
# never prebuiltkernel.org), pre-configure /etc/kpm/ + live configs, verify EVERY
# essential binary & config is present, and pack live/rootfs.squashfs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUILD_DIR="${REPO_ROOT}/build"
ROOTFS_DIR=""
SQUASHFS_OUT=""
PKG_LIST="${REPO_ROOT}/config/packages.live"
KPM_BIN="$(command -v kpm 2>/dev/null || echo /usr/bin/kpm)"
GPORTS_BIN="$(command -v gports 2>/dev/null || true)"
KPM_INI_SRC="${REPO_ROOT}/config/kpm.ini"
PUBKEY_SRC="${REPO_ROOT}/config/keys/kryx-release.pub"
LOCAL_PKG_DIR=""
KERNEL_PKG="kernel"
KERNEL_TAR=""
KERNEL_DIR=""
SQUASHFS_COMP="zstd"
VERIFY_SIG=0
SKIP_SYNC=0
ALLOW_INCOMPLETE=0

usage() {
    cat <<'EOF'
Usage: scripts/mkrootfs.sh [options]

Builds a minimal KryX Linux live rootfs strictly using `kpm` and packs live/rootfs.squashfs.

Options:
  --build-dir <dir>       Build workspace directory (default: build/)
  --rootfs <dir>          Rootfs staging directory (default: <build-dir>/rootfs)
  --squashfs <path>       Output squashfs path (default: <build-dir>/iso/live/rootfs.squashfs)
  --pkg-list <file>       Live package list file (default: config/packages.live)
  --kpm-bin <path>        Path to static `kpm` binary (default: PATH / /usr/bin/kpm)
  --gports-bin <path>     Optional path to static `gports` binary to copy into rootfs
  --local-pkgs <dir>      Directory of local .pkg.tar.* archives (selectively installs packages.live via kpm)
  --kernel-pkg <pkg|file> Custom kernel package name (in kpm index) or local .pkg.tar.* archive (default: kernel)
  --kernel-tar <tarball>  Install custom kernel from local tarball (boot/vmlinuz* + lib/modules/<ver>)
  --kernel-dir <dir>      Install kernel from local staging directory (default from Makefile: CRUX ISO kernel)
  --comp <algo>           SquashFS compression: zstd, xz, gzip (default: zstd)
  --verify                Require index.json.sig verification during kpm sync
  --no-sync               Do not run kpm sync (use cached index or --local-pkgs)
  --allow-incomplete      Warn instead of failing if an essential live binary is missing
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-dir)        BUILD_DIR="$2"; shift 2 ;;
        --rootfs)           ROOTFS_DIR="$2"; shift 2 ;;
        --squashfs)         SQUASHFS_OUT="$2"; shift 2 ;;
        --pkg-list)         PKG_LIST="$2"; shift 2 ;;
        --kpm-bin)          KPM_BIN="$2"; shift 2 ;;
        --gports-bin)       GPORTS_BIN="$2"; shift 2 ;;
        --local-pkgs)       LOCAL_PKG_DIR="$2"; shift 2 ;;
        --kernel-pkg)       KERNEL_PKG="$2"; shift 2 ;;
        --kernel-tar)       KERNEL_TAR="$2"; shift 2 ;;
        --kernel-dir)       KERNEL_DIR="$2"; shift 2 ;;
        --comp)             SQUASHFS_COMP="$2"; shift 2 ;;
        --verify)           VERIFY_SIG=1; shift ;;
        --no-sync)          SKIP_SYNC=1; shift ;;
        --allow-incomplete) ALLOW_INCOMPLETE=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "mkrootfs.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -z "$ROOTFS_DIR" ]]   && ROOTFS_DIR="${BUILD_DIR}/rootfs"
[[ -z "$SQUASHFS_OUT" ]] && SQUASHFS_OUT="${BUILD_DIR}/iso/live/rootfs.squashfs"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "mkrootfs.sh: error: must be run as root (preserving rootfs ownership & modes)" >&2
    exit 1
fi

for req in mksquashfs; do
    command -v "$req" >/dev/null 2>&1 || {
        echo "mkrootfs.sh: error: required host tool '${req}' not found in PATH" >&2
        exit 1
    }
done

if [[ ! -x "$KPM_BIN" ]]; then
    echo "mkrootfs.sh: error: kpm binary not found at '${KPM_BIN}' (pass --kpm-bin <path>)" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
BUILD_ABS="$(cd "$BUILD_DIR" && pwd)"

echo "[mkrootfs] Preparing clean live rootfs at ${ROOTFS_DIR}..."
rm -rf "$ROOTFS_DIR"
mkdir -p \
    "${ROOTFS_DIR}/bin" \
    "${ROOTFS_DIR}/boot" \
    "${ROOTFS_DIR}/dev" \
    "${ROOTFS_DIR}/etc/kpm/keys" \
    "${ROOTFS_DIR}/etc/ports/sources.list.d" \
    "${ROOTFS_DIR}/etc/profile.d" \
    "${ROOTFS_DIR}/etc/ssl/certs" \
    "${ROOTFS_DIR}/home" \
    "${ROOTFS_DIR}/lib" \
    "${ROOTFS_DIR}/mnt" \
    "${ROOTFS_DIR}/opt" \
    "${ROOTFS_DIR}/proc" \
    "${ROOTFS_DIR}/root" \
    "${ROOTFS_DIR}/run" \
    "${ROOTFS_DIR}/sbin" \
    "${ROOTFS_DIR}/sys" \
    "${ROOTFS_DIR}/tmp" \
    "${ROOTFS_DIR}/usr/bin" \
    "${ROOTFS_DIR}/usr/lib" \
    "${ROOTFS_DIR}/usr/ports" \
    "${ROOTFS_DIR}/usr/sbin" \
    "${ROOTFS_DIR}/var/cache/kpm/bin" \
    "${ROOTFS_DIR}/var/cache/kpm/sources" \
    "${ROOTFS_DIR}/var/cache/kpm/packages" \
    "${ROOTFS_DIR}/var/cache/kpm/work" \
    "${ROOTFS_DIR}/var/lib/kpm" \
    "${ROOTFS_DIR}/var/lib/pkg" \
    "${ROOTFS_DIR}/var/log" \
    "${ROOTFS_DIR}/var/tmp"

chmod 1777 "${ROOTFS_DIR}/tmp" "${ROOTFS_DIR}/var/tmp"
chmod 0750 "${ROOTFS_DIR}/root"
: > "${ROOTFS_DIR}/var/lib/pkg/db"
chmod 0444 "${ROOTFS_DIR}/var/lib/pkg/db"

# Pre-configure /etc/kpm/ and release signing key BEFORE package installation.
install -m 0644 "$KPM_INI_SRC" "${ROOTFS_DIR}/etc/kpm.ini"
install -m 0644 "$PUBKEY_SRC" "${ROOTFS_DIR}/etc/kpm/keys/kryx-release.pub"
ln -sf /etc/kpm.ini "${ROOTFS_DIR}/etc/kpm/kpm.ini"
install -m 0644 "${REPO_ROOT}/config/pkgadd.conf" "${ROOTFS_DIR}/etc/pkgadd.conf"
install -m 0644 "${REPO_ROOT}/config/sources.list" "${ROOTFS_DIR}/etc/ports/sources.list"

HOST_KPM_INI="${BUILD_ABS}/kpm.build.ini"
sed \
    -e "s|^root = .*|root = ${ROOTFS_DIR}|" \
    -e "s|^ports_dir = .*|ports_dir = ${ROOTFS_DIR}/usr/ports|" \
    -e "s|^cache_dir = .*|cache_dir = ${BUILD_ABS}/kpm-cache|" \
    -e "s|^source_cache = .*|source_cache = ${BUILD_ABS}/kpm-cache/sources|" \
    -e "s|^package_dir = .*|package_dir = ${BUILD_ABS}/kpm-cache/packages|" \
    -e "s|^work_dir = .*|work_dir = ${BUILD_ABS}/kpm-cache/work|" \
    -e "s|^pkgadd_conf = .*|pkgadd_conf = ${ROOTFS_DIR}/etc/pkgadd.conf|" \
    -e "s|^keys_dir = .*|keys_dir = ${ROOTFS_DIR}/etc/kpm/keys|" \
    -e "s|^pubkey = .*|pubkey = ${ROOTFS_DIR}/etc/kpm/keys/kryx-release.pub|" \
    "${ROOTFS_DIR}/etc/kpm.ini" > "$HOST_KPM_INI"

mkdir -p "${BUILD_ABS}/kpm-cache"

mapfile -t LIVE_PKGS < <(grep -vE '^\s*(#|$)' "$PKG_LIST")

# 1. Selectively install requested live packages from --local-pkgs via kpm
#    (preserving packages.live ordering: filesystem -> glibc -> ... without pulling bloat).
REMOTE_NEEDED=()
if [[ -n "$LOCAL_PKG_DIR" ]]; then
    if [[ ! -d "$LOCAL_PKG_DIR" ]]; then
        echo "mkrootfs.sh: error: --local-pkgs directory not found: ${LOCAL_PKG_DIR}" >&2
        exit 1
    fi
    shopt -s nullglob
    LOCAL_SELECTED=()
    for p in "${LIVE_PKGS[@]}"; do
        matches=("${LOCAL_PKG_DIR}/${p}"#*.pkg.tar.*)
        if [[ "${#matches[@]}" -gt 0 ]]; then
            LOCAL_SELECTED+=("${matches[0]}")
        else
            REMOTE_NEEDED+=("$p")
        fi
    done
    if [[ "${#LOCAL_SELECTED[@]}" -gt 0 ]]; then
        echo "[mkrootfs] Installing ${#LOCAL_SELECTED[@]} live package(s) from ${LOCAL_PKG_DIR} via kpm..."
        "$KPM_BIN" --config "$HOST_KPM_INI" --root="$ROOTFS_DIR" install --reinstall --force "${LOCAL_SELECTED[@]}"
    fi
else
    REMOTE_NEEDED=("${LIVE_PKGS[@]}")
fi

# 2. Sync remote binary index and install remaining live packages via kpm.
if [[ "$SKIP_SYNC" -eq 0 ]]; then
    SYNC_ARGS=()
    [[ "$VERIFY_SIG" -eq 1 ]] && SYNC_ARGS+=(--verify)
    echo "[mkrootfs] Syncing KryX binary index via kpm..."
    "$KPM_BIN" --config "$HOST_KPM_INI" sync "${SYNC_ARGS[@]}" || true
fi

if [[ -f "${BUILD_ABS}/kpm-cache/index.json" ]]; then
    cp -f "${BUILD_ABS}/kpm-cache/index.json" "${ROOTFS_DIR}/var/cache/kpm/index.json"
    if [[ "${#REMOTE_NEEDED[@]}" -gt 0 ]]; then
        AVAIL_INDEX="$("$KPM_BIN" --config "$HOST_KPM_INI" list --binaries | awk '{print $1}')"
        TO_INSTALL=()
        SKIPPED=()
        for p in "${REMOTE_NEEDED[@]}"; do
            if grep -qx "$p" <<< "$AVAIL_INDEX"; then
                TO_INSTALL+=("$p")
            else
                SKIPPED+=("$p")
            fi
        done
        if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
            echo "[mkrootfs] Note: package(s) not in remote index (expected via static bin or --local-pkgs): ${SKIPPED[*]}"
        fi
        if [[ "${#TO_INSTALL[@]}" -gt 0 ]]; then
            echo "[mkrootfs] Installing ${#TO_INSTALL[@]} remaining live package(s) from remote index via kpm..."
            "$KPM_BIN" --config "$HOST_KPM_INI" --root="$ROOTFS_DIR" install --deps --reinstall --force "${TO_INSTALL[@]}"
        fi
    fi
fi

# Re-apply canonical live ISO kpm/ports/pkgadd configs & release key after package installs
# so package default files never clobber the live ISO's pre-configured settings.
install -m 0644 "$KPM_INI_SRC" "${ROOTFS_DIR}/etc/kpm.ini"
install -m 0644 "$PUBKEY_SRC" "${ROOTFS_DIR}/etc/kpm/keys/kryx-release.pub"
ln -sf /etc/kpm.ini "${ROOTFS_DIR}/etc/kpm/kpm.ini"
install -m 0644 "${REPO_ROOT}/config/pkgadd.conf" "${ROOTFS_DIR}/etc/pkgadd.conf"
install -m 0644 "${REPO_ROOT}/config/sources.list" "${ROOTFS_DIR}/etc/ports/sources.list"

# 3. Install kernel (NEVER from prebuiltkernel.org):
#    Priority: --kernel-dir (default: CRUX ISO kernel) > --kernel-tar > --kernel-pkg
echo "[mkrootfs] Installing kernel..."
if [[ -n "$KERNEL_DIR" ]]; then
    if [[ ! -d "$KERNEL_DIR" ]]; then
        echo "mkrootfs.sh: error: --kernel-dir not found: ${KERNEL_DIR} (run 'make kernel' first)" >&2
        exit 1
    fi
    cp -a "${KERNEL_DIR}/." "${ROOTFS_DIR}/"
    chown -R 0:0 "${ROOTFS_DIR}/boot" "${ROOTFS_DIR}/lib/modules" 2>/dev/null || true
    [[ -d "${ROOTFS_DIR}/usr/src" ]] && chown -R 0:0 "${ROOTFS_DIR}/usr/src" 2>/dev/null || true
elif [[ -n "$KERNEL_TAR" ]]; then
    if [[ ! -f "$KERNEL_TAR" ]]; then
        echo "mkrootfs.sh: error: --kernel-tar not found: ${KERNEL_TAR}" >&2
        exit 1
    fi
    tar -xpf "$KERNEL_TAR" -C "$ROOTFS_DIR"
elif [[ -f "$KERNEL_PKG" ]]; then
    "$KPM_BIN" --config "$HOST_KPM_INI" --root="$ROOTFS_DIR" install --reinstall --force "$KERNEL_PKG"
else
    "$KPM_BIN" --config "$HOST_KPM_INI" --root="$ROOTFS_DIR" install --deps --reinstall "$KERNEL_PKG"
fi

# Locate installed kernel image and copy to <build-dir>/iso/boot/vmlinuz
VMLINUZ_SRC=""
for cand in "${ROOTFS_DIR}/boot/vmlinuz" "${ROOTFS_DIR}"/boot/vmlinuz-*; do
    if [[ -f "$cand" ]]; then
        VMLINUZ_SRC="$cand"
        break
    fi
done
if [[ -z "$VMLINUZ_SRC" ]]; then
    echo "mkrootfs.sh: error: no vmlinuz kernel image found under ${ROOTFS_DIR}/boot/" >&2
    exit 1
fi
mkdir -p "${BUILD_ABS}/iso/boot"
cp -L "$VMLINUZ_SRC" "${BUILD_ABS}/iso/boot/vmlinuz"
chmod 0644 "${BUILD_ABS}/iso/boot/vmlinuz"
echo "[mkrootfs] Kernel staged at ${BUILD_ABS}/iso/boot/vmlinuz (from $(basename "$VMLINUZ_SRC"))"

# 4. Ensure static kpm, gports, compatibility symlinks, and live installer scripts are present.
if [[ ! -x "${ROOTFS_DIR}/usr/bin/kpm" ]]; then
    install -m 0755 "$KPM_BIN" "${ROOTFS_DIR}/usr/bin/kpm"
fi
for link in pkgadd pkgrm pkginfo pkgmk ports rejmerge; do
    ln -sf kpm "${ROOTFS_DIR}/usr/bin/${link}"
done
if [[ -n "$GPORTS_BIN" && -x "$GPORTS_BIN" && ! -x "${ROOTFS_DIR}/usr/bin/gports" ]]; then
    install -m 0755 "$GPORTS_BIN" "${ROOTFS_DIR}/usr/bin/gports"
fi

install -m 0755 "${REPO_ROOT}/bin/setup"        "${ROOTFS_DIR}/usr/bin/setup"
install -m 0755 "${REPO_ROOT}/bin/setup-chroot" "${ROOTFS_DIR}/usr/bin/setup-chroot"

# 5. Install minimal live system configs (/etc/inittab, /etc/rc, /etc/issue, /etc/motd, etc.).
install -m 0644 "${REPO_ROOT}/config/inittab"     "${ROOTFS_DIR}/etc/inittab"
install -m 0755 "${REPO_ROOT}/config/rc"          "${ROOTFS_DIR}/etc/rc"
install -m 0755 "${REPO_ROOT}/config/rc.shutdown" "${ROOTFS_DIR}/etc/rc.shutdown"
install -m 0644 "${REPO_ROOT}/config/fstab"       "${ROOTFS_DIR}/etc/fstab"
install -m 0644 "${REPO_ROOT}/config/issue"       "${ROOTFS_DIR}/etc/issue"
install -m 0644 "${REPO_ROOT}/config/motd"        "${ROOTFS_DIR}/etc/motd"

echo "kryx-live" > "${ROOTFS_DIR}/etc/hostname"

cat > "${ROOTFS_DIR}/etc/os-release" <<'EOF'
NAME="KryX Linux"
ID=kryx
ID_LIKE=crux
PRETTY_NAME="KryX Linux Live (x86_64)"
HOME_URL="https://kryx.anrix.org"
EOF

cat > "${ROOTFS_DIR}/etc/profile.d/kryx-live.sh" <<'EOF'
export PATH="/sbin:/usr/sbin:/bin:/usr/bin"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export KPM_CONFIG="${KPM_CONFIG:-/etc/kpm.ini}"
EOF
chmod 0644 "${ROOTFS_DIR}/etc/profile.d/kryx-live.sh"

# Ensure CA bundle compatibility symlink exists when ca-certificates is installed.
if [[ -s "${ROOTFS_DIR}/etc/ssl/cert.pem" ]]; then
    ln -sf ../cert.pem "${ROOTFS_DIR}/etc/ssl/certs/ca-certificates.crt"
fi

# Ensure passwordless root login inside the live TTY environment.
if [[ -f "${ROOTFS_DIR}/etc/shadow" ]]; then
    sed -i 's|^root:[^:]*:|root::|' "${ROOTFS_DIR}/etc/shadow"
fi

# Ensure /bin/sh exists (provided by core/dash; fall back to bash if absent).
if [[ ! -e "${ROOTFS_DIR}/bin/sh" && -x "${ROOTFS_DIR}/bin/bash" ]]; then
    ln -sf bash "${ROOTFS_DIR}/bin/sh"
fi

# Refresh ldconfig cache inside rootfs if ldconfig is present on host.
if command -v ldconfig >/dev/null 2>&1 && [[ -f "${ROOTFS_DIR}/etc/ld.so.conf" ]]; then
    ldconfig -r "$ROOTFS_DIR" 2>/dev/null || true
fi

# 6. Strict completeness check: ensure core & essential live binaries/configs are present.
echo "[mkrootfs] Verifying core & essential live binaries and configs..."
MISSING_ESSENTIALS=()

check_any_path() {
    local label="$1"
    shift
    local rel
    for rel in "$@"; do
        if [[ -e "${ROOTFS_DIR}/${rel}" ]]; then
            return 0
        fi
    done
    MISSING_ESSENTIALS+=("${label}")
}

check_any_path "glibc (libc.so.6)"        lib/libc.so.6 lib64/libc.so.6 usr/lib/libc.so.6
check_any_path "POSIX /bin/sh"            bin/sh usr/bin/sh
check_any_path "bash"                     bin/bash usr/bin/bash
check_any_path "login (shadow)"           bin/login usr/bin/login
check_any_path "linux-pam (libpam.so.0)"  lib/libpam.so.0 usr/lib/libpam.so.0
check_any_path "libbsd (libbsd.so.0)"     lib/libbsd.so.0 usr/lib/libbsd.so.0
check_any_path "libmd (libmd.so.0)"       lib/libmd.so.0 usr/lib/libmd.so.0
check_any_path "libgmp (libgmp.so.10)"    lib/libgmp.so.10 usr/lib/libgmp.so.10
check_any_path "libdevmapper"             lib/libdevmapper.so.1.02 usr/lib/libdevmapper.so.1.02
check_any_path "sysvinit (/sbin/init)"    sbin/init usr/sbin/init
check_any_path "agetty"                   sbin/agetty usr/sbin/agetty
check_any_path "mount (util-linux)"       bin/mount usr/bin/mount
check_any_path "fdisk/cfdisk"             sbin/fdisk usr/sbin/fdisk sbin/cfdisk usr/sbin/cfdisk
check_any_path "mkfs.ext4 (e2fsprogs)"    sbin/mkfs.ext4 usr/sbin/mkfs.ext4
check_any_path "mkfs.fat (dosfstools)"    sbin/mkfs.fat usr/sbin/mkfs.fat sbin/mkfs.vfat usr/sbin/mkfs.vfat
check_any_path "ip (iproute2)"            sbin/ip usr/sbin/ip bin/ip usr/bin/ip
check_any_path "dhcpcd"                   sbin/dhcpcd usr/sbin/dhcpcd
check_any_path "curl"                     usr/bin/curl bin/curl
check_any_path "tar"                      bin/tar usr/bin/tar
check_any_path "xz"                       usr/bin/xz bin/xz
check_any_path "zstd"                     usr/bin/zstd bin/zstd
check_any_path "kpm"                      usr/bin/kpm
check_any_path "setup installer"          usr/bin/setup
check_any_path "setup-chroot"             usr/bin/setup-chroot
check_any_path "kpm.ini"                  etc/kpm.ini
check_any_path "kryx-release.pub"         etc/kpm/keys/kryx-release.pub
check_any_path "inittab"                  etc/inittab
check_any_path "kernel vmlinuz"           boot/vmlinuz

if [[ "${#MISSING_ESSENTIALS[@]}" -gt 0 ]]; then
    echo "[mkrootfs] ERROR: Live rootfs is missing essential component(s):" >&2
    printf '  - %s\n' "${MISSING_ESSENTIALS[@]}" >&2
    if [[ "$ALLOW_INCOMPLETE" -eq 0 ]]; then
        echo "[mkrootfs] Run 'scripts/build-essential-pkgs.sh' (or provide --local-pkgs) so all core & live packages are installed." >&2
        exit 1
    else
        echo "[mkrootfs] WARNING: continuing due to --allow-incomplete" >&2
    fi
else
    echo "[mkrootfs] All core & essential live components verified present."
fi

# 7. Pack live rootfs into SquashFS image.
mkdir -p "$(dirname "$SQUASHFS_OUT")"
rm -f "$SQUASHFS_OUT"
echo "[mkrootfs] Packing ${SQUASHFS_OUT} (compression=${SQUASHFS_COMP})..."
mksquashfs "$ROOTFS_DIR" "$SQUASHFS_OUT" \
    -comp "$SQUASHFS_COMP" \
    -noappend \
    -wildcards \
    -e "tmp/*" "var/tmp/*" "var/cache/kpm/bin/*" "var/cache/kpm/sources/*" "var/cache/kpm/work/*"

ls -lh "$SQUASHFS_OUT"
echo "[mkrootfs] Done."
