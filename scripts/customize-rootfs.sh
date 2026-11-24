#!/usr/bin/env bash
# Customize an extracted CRUX rootfs for CI/GitHub Actions and pack a reproducible tarball.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ROOTFS_DIR="${REPO_ROOT}/build/rootfs"
KPM_BIN="${REPO_ROOT}/build/bin/kpm"
KPM_INDEX_BIN="${REPO_ROOT}/build/bin/kpm-index"
KRYX_SRC_BIN="${REPO_ROOT}/build/bin/kryx-src"
GPORTS_BIN="${REPO_ROOT}/build/bin/gports"
KPM_INI="${REPO_ROOT}/config/kpm.ini"
PUBKEY_SRC="${REPO_ROOT}/config/keys/kryx-release.pub"
SOURCES_LIST_SRC="${REPO_ROOT}/config/sources.list"
PORTS_CORE_DIR=""
PORTS_CORE_REPO="https://github.com/kryx-linux/core.git"
PORTS_CORE_REF="main"
SKIP_PORTS=0
CA_BUNDLE=""
TARBALL_OUT="${REPO_ROOT}/build/kryx-rootfs.tar.xz"
SKIP_TARBALL=0

usage() {
    cat <<'EOF'
Usage: scripts/customize-rootfs.sh [options]

Options:
  --rootfs <dir>            Prepared CRUX rootfs directory (default: build/rootfs)
  --kpm-bin <path>          Path to static kpm binary (default: build/bin/kpm)
  --kpm-index-bin <path>    Path to static kpm-index binary (default: build/bin/kpm-index)
  --kpm-ini <path>          Default kpm.ini file to install at /etc/kpm.ini (default: config/kpm.ini)
  --ports-core-dir <dir>    Copy /usr/ports/core from a local checkout
  --ports-core-repo <url>   Clone /usr/ports/core from Git when --ports-core-dir is omitted
  --ports-core-ref <ref>    Git branch/tag for /usr/ports/core (default: 3.8)
  --skip-ports              Do not populate /usr/ports/core
  --ca-bundle <path>        Fallback CA bundle PEM if /etc/ssl/cert.pem is absent
  --tarball <path>          Output rootfs tarball path (default: build/crux-rootfs.tar.xz)
  --skip-tarball            Customize rootfs in place without creating the tarball
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rootfs)
            ROOTFS_DIR="$2"
            shift 2
            ;;
        --kpm-bin)
            KPM_BIN="$2"
            shift 2
            ;;
        --kpm-index-bin)
            KPM_INDEX_BIN="$2"
            shift 2
            ;;
        --kpm-ini)
            KPM_INI="$2"
            shift 2
            ;;
        --ports-core-dir)
            PORTS_CORE_DIR="$2"
            shift 2
            ;;
        --ports-core-repo)
            PORTS_CORE_REPO="$2"
            shift 2
            ;;
        --ports-core-ref)
            PORTS_CORE_REF="$2"
            shift 2
            ;;
        --skip-ports)
            SKIP_PORTS=1
            shift
            ;;
        --ca-bundle)
            CA_BUNDLE="$2"
            shift 2
            ;;
        --tarball)
            TARBALL_OUT="$2"
            shift 2
            ;;
        --skip-tarball)
            SKIP_TARBALL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "customize-rootfs.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "$ROOTFS_DIR" ]]; then
    echo "customize-rootfs.sh: error: rootfs directory not found: ${ROOTFS_DIR}" >&2
    exit 1
fi
ROOTFS_ABS="$(cd "$ROOTFS_DIR" && pwd)"

for req in "$KPM_BIN" "$KPM_INDEX_BIN" "$KPM_INI"; do
    if [[ ! -f "$req" ]]; then
        echo "customize-rootfs.sh: error: required file not found: ${req}" >&2
        exit 1
    fi
done

echo "[customize-rootfs] Customizing CRUX rootfs at ${ROOTFS_ABS}..."

# 1. Ensure essential directories and permissions exist.
mkdir -p \
    "${ROOTFS_ABS}/etc" \
    "${ROOTFS_ABS}/etc/kpm/keys" \
    "${ROOTFS_ABS}/etc/gports/sources.list.d" \
    "${ROOTFS_ABS}/etc/profile.d" \
    "${ROOTFS_ABS}/etc/ports" \
    "${ROOTFS_ABS}/etc/ssl/certs" \
    "${ROOTFS_ABS}/usr/bin" \
    "${ROOTFS_ABS}/usr/ports" \
    "${ROOTFS_ABS}/var/cache/kpm/bin" \
    "${ROOTFS_ABS}/var/cache/kpm/sources" \
    "${ROOTFS_ABS}/var/cache/kpm/packages" \
    "${ROOTFS_ABS}/var/cache/kpm/work" \
    "${ROOTFS_ABS}/var/lib/kpm" \
    "${ROOTFS_ABS}/var/lib/pkg" \
    "${ROOTFS_ABS}/var/tmp" \
    "${ROOTFS_ABS}/tmp" \
    "${ROOTFS_ABS}/root"

chmod 1777 "${ROOTFS_ABS}/tmp" "${ROOTFS_ABS}/var/tmp"
chmod 0750 "${ROOTFS_ABS}/root"

# 2. Install kpm, kpm-index, kryx-src, gports (if built), CRUX symlinks, release key, and configs.
install -m 0755 "$KPM_BIN" "${ROOTFS_ABS}/usr/bin/kpm"
install -m 0755 "$KPM_INDEX_BIN" "${ROOTFS_ABS}/usr/bin/kpm-index"
if [[ -f "$KRYX_SRC_BIN" ]]; then
    install -m 0755 "$KRYX_SRC_BIN" "${ROOTFS_ABS}/usr/bin/kryx-src"
fi
if [[ -f "$GPORTS_BIN" ]]; then
    install -m 0755 "$GPORTS_BIN" "${ROOTFS_ABS}/usr/bin/gports"
fi
for link in pkgadd pkgrm pkginfo pkgmk ports rejmerge; do
    ln -sf kpm "${ROOTFS_ABS}/usr/bin/${link}"
done
install -m 0644 "$KPM_INI" "${ROOTFS_ABS}/etc/kpm.ini"
ln -sf /etc/kpm.ini "${ROOTFS_ABS}/etc/kpm/kpm.ini"
if [[ -f "$PUBKEY_SRC" ]]; then
    install -m 0644 "$PUBKEY_SRC" "${ROOTFS_ABS}/etc/kpm/keys/kryx-release.pub"
fi
if [[ -f "$SOURCES_LIST_SRC" ]]; then
    install -m 0644 "$SOURCES_LIST_SRC" "${ROOTFS_ABS}/etc/gports/sources.list"
fi

# 3. Verify CA certificates (/etc/ssl/cert.pem from CRUX ca-certificates) and add compatibility symlink.
if [[ ! -s "${ROOTFS_ABS}/etc/ssl/cert.pem" ]]; then
    if [[ -n "$CA_BUNDLE" && -s "$CA_BUNDLE" ]]; then
        install -m 0644 "$CA_BUNDLE" "${ROOTFS_ABS}/etc/ssl/cert.pem"
    elif [[ -s /etc/ssl/certs/ca-certificates.crt ]]; then
        install -m 0644 /etc/ssl/certs/ca-certificates.crt "${ROOTFS_ABS}/etc/ssl/cert.pem"
    elif [[ -s /etc/pki/tls/certs/ca-bundle.crt ]]; then
        install -m 0644 /etc/pki/tls/certs/ca-bundle.crt "${ROOTFS_ABS}/etc/ssl/cert.pem"
    elif [[ -s /etc/ssl/cert.pem ]]; then
        install -m 0644 /etc/ssl/cert.pem "${ROOTFS_ABS}/etc/ssl/cert.pem"
    else
        echo "[customize-rootfs] Warning: /etc/ssl/cert.pem is missing and no fallback CA bundle was found" >&2
    fi
fi
if [[ -s "${ROOTFS_ABS}/etc/ssl/cert.pem" ]]; then
    ln -sf ../cert.pem "${ROOTFS_ABS}/etc/ssl/certs/ca-certificates.crt"
fi

# 4. Network & resolver defaults for CI containers (Docker bind-mounts /etc/resolv.conf at runtime).
if [[ ! -s "${ROOTFS_ABS}/etc/nsswitch.conf" ]]; then
    cat > "${ROOTFS_ABS}/etc/nsswitch.conf" <<'EOF'
# /etc/nsswitch.conf: name service switch configuration file
passwd:      files
group:       files
shadow:      files

hosts:       files dns
networks:    files

services:    files
protocols:   files
rpc:         files
ethers:      files
netmasks:    files
netgroup:    files
EOF
    chmod 0644 "${ROOTFS_ABS}/etc/nsswitch.conf"
fi

if [[ ! -s "${ROOTFS_ABS}/etc/hosts" ]]; then
    cat > "${ROOTFS_ABS}/etc/hosts" <<'EOF'
127.0.0.1	localhost
::1		localhost ip6-localhost ip6-loopback
EOF
    chmod 0644 "${ROOTFS_ABS}/etc/hosts"
fi

if [[ ! -f "${ROOTFS_ABS}/etc/resolv.conf" ]] || ! grep -q '^nameserver ' "${ROOTFS_ABS}/etc/resolv.conf"; then
    cat > "${ROOTFS_ABS}/etc/resolv.conf" <<'EOF'
# Default fallback DNS for build/chroot environments (overridden by container runtime)
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
    chmod 0644 "${ROOTFS_ABS}/etc/resolv.conf"
fi

# 5. Timezone, locale, and shell PATH defaults.
if [[ -f "${ROOTFS_ABS}/usr/share/zoneinfo/UTC" ]]; then
    ln -sf ../usr/share/zoneinfo/UTC "${ROOTFS_ABS}/etc/localtime"
fi

cat > "${ROOTFS_ABS}/etc/profile.d/crux-ci.sh" <<'EOF'
# CRUX CI container defaults
export PATH="/sbin:/usr/sbin:/opt/sbin:/bin:/usr/bin:/opt/bin"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"
export KPM_CONFIG="${KPM_CONFIG:-/etc/kpm.ini}"
EOF
chmod 0644 "${ROOTFS_ABS}/etc/profile.d/crux-ci.sh"

# Ensure /etc/profile sources /etc/profile.d/*.sh for login shells.
if [[ -f "${ROOTFS_ABS}/etc/profile" ]]; then
    if ! grep -q '/etc/profile.d' "${ROOTFS_ABS}/etc/profile"; then
        cat >> "${ROOTFS_ABS}/etc/profile" <<'EOF'

if [ -d /etc/profile.d ]; then
    for f in /etc/profile.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
    unset f
fi
EOF
    fi
else
    cat > "${ROOTFS_ABS}/etc/profile" <<'EOF'
export PATH="/sbin:/usr/sbin:/opt/sbin:/bin:/usr/bin:/opt/bin"
umask 022

if [ -d /etc/profile.d ]; then
    for f in /etc/profile.d/*.sh; do
        [ -r "$f" ] && . "$f"
    done
    unset f
fi
EOF
    chmod 0644 "${ROOTFS_ABS}/etc/profile"
fi

# 6. Populate /usr/ports/core so `kpm list --ports` and `kpm build` work immediately.
if [[ "$SKIP_PORTS" -eq 0 ]]; then
    rm -rf "${ROOTFS_ABS}/usr/ports/core"
    mkdir -p "${ROOTFS_ABS}/usr/ports/core"
    if [[ -n "$PORTS_CORE_DIR" ]]; then
        if [[ ! -d "$PORTS_CORE_DIR" ]]; then
            echo "customize-rootfs.sh: error: --ports-core-dir not found: ${PORTS_CORE_DIR}" >&2
            exit 1
        fi
        echo "[customize-rootfs] Copying /usr/ports/core from ${PORTS_CORE_DIR}..."
        (cd "$PORTS_CORE_DIR" && tar --exclude='.git' -cf - .) | tar -xf - -C "${ROOTFS_ABS}/usr/ports/core"
    else
        command -v git >/dev/null 2>&1 || {
            echo "customize-rootfs.sh: error: 'git' is required to fetch ${PORTS_CORE_REPO}" >&2
            exit 1
        }
        echo "[customize-rootfs] Cloning /usr/ports/core (${PORTS_CORE_REPO} @ ${PORTS_CORE_REF})..."
        git clone --depth 1 --branch "$PORTS_CORE_REF" "$PORTS_CORE_REPO" "${ROOTFS_ABS}/usr/ports/core" 2>/dev/null || \
            git clone --depth 1 --branch "3.8" "https://git.crux.nu/ports/core.git" "${ROOTFS_ABS}/usr/ports/core"
        rm -rf "${ROOTFS_ABS}/usr/ports/core/.git"
    fi
fi

# 7. Refresh shared library cache when running as root.
if [[ "$(id -u)" -eq 0 ]] && [[ -f "${ROOTFS_ABS}/etc/ld.so.conf" ]]; then
    if command -v ldconfig >/dev/null 2>&1; then
        echo "[customize-rootfs] Updating /etc/ld.so.cache..."
        ldconfig -r "$ROOTFS_ABS" 2>/dev/null || true
    fi
fi

# 8. Cleanup transient files before packing.
rm -rf \
    "${ROOTFS_ABS}/tmp/"* \
    "${ROOTFS_ABS}/var/tmp/"* \
    "${ROOTFS_ABS}/var/lib/pkg/.incomplete_transaction" \
    "${ROOTFS_ABS}/var/lib/pkg/.backup"

if [[ "$SKIP_TARBALL" -eq 1 ]]; then
    echo "[customize-rootfs] Skipping tarball creation (--skip-tarball)."
    exit 0
fi

# 9. Pack reproducible rootfs tarball.
mkdir -p "$(dirname "$TARBALL_OUT")"
TARBALL_ABS="$(cd "$(dirname "$TARBALL_OUT")" && pwd)/$(basename "$TARBALL_OUT")"

echo "[customize-rootfs] Packing rootfs tarball: ${TARBALL_ABS}..."

TAR_FLAGS=(--numeric-owner -cf -)
if tar --help 2>/dev/null | grep -- '--sort=' >/dev/null; then
    TAR_FLAGS=(--sort=name --numeric-owner -cf -)
fi

case "$TARBALL_ABS" in
    *.tar.xz|*.txz)
        (cd "$ROOTFS_ABS" && tar "${TAR_FLAGS[@]}" .) | xz -T0 -6 > "${TARBALL_ABS}.tmp"
        ;;
    *.tar.zst|*.tzst)
        (cd "$ROOTFS_ABS" && tar "${TAR_FLAGS[@]}" .) | zstd -T0 -12 -q > "${TARBALL_ABS}.tmp"
        ;;
    *.tar.gz|*.tgz)
        (cd "$ROOTFS_ABS" && tar "${TAR_FLAGS[@]}" .) | gzip -9 > "${TARBALL_ABS}.tmp"
        ;;
    *.tar)
        (cd "$ROOTFS_ABS" && tar "${TAR_FLAGS[@]}" .) > "${TARBALL_ABS}.tmp"
        ;;
    *)
        echo "customize-rootfs.sh: error: unsupported tarball extension: ${TARBALL_ABS}" >&2
        exit 2
        ;;
esac

mv -f "${TARBALL_ABS}.tmp" "$TARBALL_ABS"
ls -lh "$TARBALL_ABS"
sha256sum "$TARBALL_ABS"
