#!/usr/bin/env bash
# Extract and assemble a clean CRUX Linux base rootfs from a CRUX ISO, package directory,
# rootfs tarball, or squashfs image.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_ISO_URL="https://git.crux.nu/system/iso/releases/download/3.8-updated/crux-3.8-updated.iso"

ISO_PATH=""
ISO_URL="$DEFAULT_ISO_URL"
ISO_SHA256=""
PKG_DIR=""
ROOTFS_TAR=""
SQUASHFS_PATH=""
OUTPUT_DIR="${REPO_ROOT}/build/rootfs"
WORK_DIR="${REPO_ROOT}/build/work"
KPM_BIN="${REPO_ROOT}/build/bin/kpm"
EXCLUDE_FILE="${REPO_ROOT}/config/core-exclude.txt"
FULL_CORE=0
INCLUDE_OPT=""
SAVE_PKGS_DIR=""
INSTALLER_MODE="auto"

usage() {
    cat <<'EOF'
Usage: scripts/extract-rootfs.sh [options]

Source options (mutually exclusive; defaults to downloading upstream rolling CRUX ISO):
  --iso <path>              Path to a local CRUX ISO image
  --iso-url <url>           URL to download CRUX ISO (default: CRUX 3.8-updated ISO)
  --iso-sha256 <hex>        Optional expected SHA-256 checksum for the ISO
  --pkg-dir <dir>           Install directly from a directory of CRUX .pkg.tar.* packages
  --rootfs-tar <path>       Extract an existing rootfs tarball directly
  --squashfs <path>         Extract an existing squashfs rootfs via unsquashfs

Build options:
  --output <dir>            Target rootfs directory (default: build/rootfs)
  --work-dir <dir>          Working/cache directory (default: build/work)
  --kpm-bin <path>          Path to static kpm binary (default: build/bin/kpm)
  --exclude-file <path>     CRUX core package exclusion list (default: config/core-exclude.txt)
  --full-core               Install every package in CRUX core (ignore --exclude-file)
  --include-opt <csv>       Comma-separated extra package names to include from ISO /crux/opt
  --save-pkgs <dir>         Copy extracted ISO core + opt .pkg.tar.* archives into <dir> for ISO builds
  --installer-mode <mode>   Package installer: auto, kpm, pkgadd, bsdtar (default: auto)
  -h, --help                Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)
            ISO_PATH="$2"
            shift 2
            ;;
        --iso-url)
            ISO_URL="$2"
            shift 2
            ;;
        --iso-sha256)
            ISO_SHA256="$2"
            shift 2
            ;;
        --pkg-dir)
            PKG_DIR="$2"
            shift 2
            ;;
        --rootfs-tar)
            ROOTFS_TAR="$2"
            shift 2
            ;;
        --squashfs)
            SQUASHFS_PATH="$2"
            shift 2
            ;;
        --output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --kpm-bin)
            KPM_BIN="$2"
            shift 2
            ;;
        --exclude-file)
            EXCLUDE_FILE="$2"
            shift 2
            ;;
        --full-core)
            FULL_CORE=1
            shift
            ;;
        --include-opt)
            INCLUDE_OPT="$2"
            shift 2
            ;;
        --save-pkgs)
            SAVE_PKGS_DIR="$2"
            shift 2
            ;;
        --installer-mode)
            INSTALLER_MODE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "extract-rootfs.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

MOUNT_DIR=""
TMP_KPM_INI=""
cleanup() {
    if [[ -n "$MOUNT_DIR" ]] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount "$MOUNT_DIR" || true
    fi
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
    if [[ -n "$TMP_KPM_INI" && -f "$TMP_KPM_INI" ]]; then
        rm -f "$TMP_KPM_INI"
    fi
}
trap cleanup EXIT

mkdir -p "$WORK_DIR"
WORK_DIR_ABS="$(cd "$WORK_DIR" && pwd)"

if [[ -e "$OUTPUT_DIR" ]]; then
    echo "[extract-rootfs] Cleaning existing rootfs directory: ${OUTPUT_DIR}"
    rm -rf "$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR_ABS="$(cd "$OUTPUT_DIR" && pwd)"

verify_sha256() {
    local file="$1"
    local expected="$2"
    if [[ -z "$expected" ]]; then
        return 0
    fi
    echo "[extract-rootfs] Verifying SHA-256 checksum for $(basename "$file")..."
    local actual
    actual="$(sha256sum "$file" | awk '{print $1}')"
    if [[ "${actual,,}" != "${expected,,}" ]]; then
        echo "extract-rootfs.sh: checksum mismatch for ${file}" >&2
        echo "  expected: ${expected}" >&2
        echo "  actual:   ${actual}" >&2
        exit 1
    fi
}

download_iso() {
    local url="$1"
    local dest_dir="${WORK_DIR_ABS}/iso"
    mkdir -p "$dest_dir"
    local filename
    filename="$(basename "${url%%\?*}")"
    local dest="${dest_dir}/${filename}"

    if [[ -f "$dest" ]]; then
        echo "[extract-rootfs] Reusing cached ISO: ${dest}"
    else
        echo "[extract-rootfs] Downloading CRUX ISO from ${url}..."
        if command -v curl >/dev/null 2>&1; then
            curl -fL --retry 3 --retry-delay 5 -o "${dest}.part" "$url"
        elif command -v wget >/dev/null 2>&1; then
            wget --tries=3 -O "${dest}.part" "$url"
        else
            echo "extract-rootfs.sh: error: neither curl nor wget is available" >&2
            exit 1
        fi
        mv -f "${dest}.part" "$dest"
    fi

    verify_sha256 "$dest" "$ISO_SHA256"
    ISO_PATH="$dest"
}

extract_iso_contents() {
    local iso_file="$1"
    local dest_dir="$2"
    rm -rf "$dest_dir"
    mkdir -p "$dest_dir"

    local extract_paths=("crux/core" "crux-media")
    if [[ -n "$INCLUDE_OPT" || -n "$SAVE_PKGS_DIR" ]]; then
        extract_paths+=("crux/opt")
    fi

    if command -v bsdtar >/dev/null 2>&1; then
        echo "[extract-rootfs] Extracting ISO packages using bsdtar..."
        bsdtar -xf "$iso_file" -C "$dest_dir" "${extract_paths[@]}" 2>/dev/null || \
            bsdtar -xf "$iso_file" -C "$dest_dir" "crux/core"
    elif command -v xorriso >/dev/null 2>&1; then
        echo "[extract-rootfs] Extracting ISO packages using xorriso..."
        mkdir -p "${dest_dir}/crux"
        xorriso -osirrox on -indev "$iso_file" -extract /crux/core "${dest_dir}/crux/core"
        xorriso -osirrox on -indev "$iso_file" -extract /crux-media "${dest_dir}/crux-media" 2>/dev/null || true
        if [[ -n "$INCLUDE_OPT" || -n "$SAVE_PKGS_DIR" ]]; then
            xorriso -osirrox on -indev "$iso_file" -extract /crux/opt "${dest_dir}/crux/opt" 2>/dev/null || true
        fi
    elif command -v 7z >/dev/null 2>&1; then
        echo "[extract-rootfs] Extracting ISO packages using 7z..."
        7z x -y -o"$dest_dir" "$iso_file" "${extract_paths[@]}" >/dev/null
    elif [[ "$(id -u)" -eq 0 ]] && command -v mount >/dev/null 2>&1; then
        echo "[extract-rootfs] Extracting ISO packages via loop mount..."
        MOUNT_DIR="$(mktemp -d "${WORK_DIR_ABS}/iso-mnt.XXXXXX")"
        mount -o loop,ro "$iso_file" "$MOUNT_DIR"
        mkdir -p "${dest_dir}/crux"
        cp -a "${MOUNT_DIR}/crux/core" "${dest_dir}/crux/core"
        if [[ -f "${MOUNT_DIR}/crux-media" ]]; then
            cp -a "${MOUNT_DIR}/crux-media" "${dest_dir}/crux-media"
        fi
        if [[ ( -n "$INCLUDE_OPT" || -n "$SAVE_PKGS_DIR" ) && -d "${MOUNT_DIR}/crux/opt" ]]; then
            cp -a "${MOUNT_DIR}/crux/opt" "${dest_dir}/crux/opt"
        fi
        umount "$MOUNT_DIR"
        rmdir "$MOUNT_DIR"
        MOUNT_DIR=""
    else
        echo "extract-rootfs.sh: error: need bsdtar, xorriso, 7z, or root loop mount to read ISO" >&2
        exit 1
    fi
}

load_exclusions() {
    declare -gA EXCLUDED_PKGS=()
    if [[ "$FULL_CORE" -eq 1 ]]; then
        echo "[extract-rootfs] --full-core enabled: installing all CRUX core packages"
        return 0
    fi
    if [[ ! -f "$EXCLUDE_FILE" ]]; then
        echo "[extract-rootfs] Warning: exclude file ${EXCLUDE_FILE} not found; installing all packages" >&2
        return 0
    fi
    local line pkg
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        pkg="$(printf '%s' "$line" | xargs || true)"
        if [[ -n "$pkg" ]]; then
            EXCLUDED_PKGS["$pkg"]=1
        fi
    done < "$EXCLUDE_FILE"
    echo "[extract-rootfs] Loaded ${#EXCLUDED_PKGS[@]} excluded packages from ${EXCLUDE_FILE}"
}

pkg_name_from_file() {
    local base
    base="$(basename "$1")"
    printf '%s\n' "${base%%#*}"
}

pkg_version_from_file() {
    local base rest
    base="$(basename "$1")"
    rest="${base#*#}"
    printf '%s\n' "${rest%.pkg.tar.*}"
}

choose_installer() {
    if [[ "$INSTALLER_MODE" != "auto" ]]; then
        printf '%s\n' "$INSTALLER_MODE"
        return 0
    fi
    if [[ "$(id -u)" -eq 0 ]]; then
        if [[ -x "$KPM_BIN" ]]; then
            printf 'kpm\n'
            return 0
        fi
        if command -v pkgadd >/dev/null 2>&1; then
            printf 'pkgadd\n'
            return 0
        fi
    fi
    printf 'bsdtar\n'
}

install_pkg_bsdtar() {
    local pkg_file="$1"
    local root_dir="$2"
    local name version
    name="$(pkg_name_from_file "$pkg_file")"
    version="$(pkg_version_from_file "$pkg_file")"

    # Extract preserving permissions, symlinks, and hardlinks.
    bsdtar -xpf "$pkg_file" -C "$root_dir"

    # Record CRUX pkgutils-compatible package database entry.
    {
        printf '%s\n' "$name"
        printf '%s\n' "$version"
        bsdtar -tf "$pkg_file" \
            | sed -e 's|^\./||' -e 's|^/||' \
            | grep -v '^$' \
            | grep -v '^\.$' \
            | LC_ALL=C sort -u
        printf '\n'
    } >> "${root_dir}/var/lib/pkg/db"
}

install_packages() {
    local core_dir="$1"
    local opt_dir="${2:-}"

    if [[ ! -d "$core_dir" ]]; then
        echo "extract-rootfs.sh: error: package directory not found: ${core_dir}" >&2
        exit 1
    fi

    load_exclusions

    local installer
    installer="$(choose_installer)"
    echo "[extract-rootfs] Installing packages using mode: ${installer}"
    if [[ "$installer" == "bsdtar" && "$(id -u)" -ne 0 ]]; then
        echo "[extract-rootfs] Note: running unprivileged bsdtar fallback (suitable for local dry-runs; use root/sudo for production rootfs ownership)." >&2
    fi

    mkdir -p "${OUTPUT_DIR_ABS}/var/lib/pkg"
    : > "${OUTPUT_DIR_ABS}/var/lib/pkg/db"

    if [[ "$installer" == "kpm" ]]; then
        TMP_KPM_INI="$(mktemp "${WORK_DIR_ABS}/kpm-extract.XXXXXX.ini")"
        cat > "$TMP_KPM_INI" <<EOF
[paths]
root = ${OUTPUT_DIR_ABS}
pkgadd_conf = ${OUTPUT_DIR_ABS}/etc/pkgadd.conf
EOF
    fi

    shopt -s nullglob
    local all_core=("${core_dir}"/*.pkg.tar.*)
    if [[ "${#all_core[@]}" -eq 0 ]]; then
        echo "extract-rootfs.sh: error: no .pkg.tar.* archives found in ${core_dir}" >&2
        exit 1
    fi

    # Order critical base packages first: filesystem -> glibc -> pkgutils -> rest.
    local ordered=()
    local rest=()
    local pkg name
    for pkg in "${all_core[@]}"; do
        name="$(pkg_name_from_file "$pkg")"
        if [[ -n "${EXCLUDED_PKGS[$name]+x}" ]]; then
            continue
        fi
        case "$name" in
            filesystem|glibc|pkgutils) ;;
            *) rest+=("$pkg") ;;
        esac
    done

    for priority in filesystem glibc pkgutils; do
        for pkg in "${all_core[@]}"; do
            name="$(pkg_name_from_file "$pkg")"
            if [[ "$name" == "$priority" && -z "${EXCLUDED_PKGS[$name]+x}" ]]; then
                ordered+=("$pkg")
            fi
        done
    done

    if [[ "${#rest[@]}" -gt 0 ]]; then
        while IFS= read -r pkg; do
            ordered+=("$pkg")
        done < <(printf '%s\n' "${rest[@]}" | LC_ALL=C sort)
    fi

    # Add optional requested packages from /crux/opt if specified.
    if [[ -n "$INCLUDE_OPT" ]]; then
        if [[ ! -d "$opt_dir" ]]; then
            echo "extract-rootfs.sh: error: --include-opt specified, but ${opt_dir} does not exist" >&2
            exit 1
        fi
        local IFS=','
        local opt_req matches
        for opt_req in $INCLUDE_OPT; do
            opt_req="$(printf '%s' "$opt_req" | xargs)"
            [[ -z "$opt_req" ]] && continue
            matches=("${opt_dir}/${opt_req}"#*.pkg.tar.*)
            if [[ "${#matches[@]}" -eq 0 ]]; then
                echo "extract-rootfs.sh: error: requested opt package '${opt_req}' not found in ${opt_dir}" >&2
                exit 1
            fi
            ordered+=("${matches[0]}")
        done
    fi

    echo "[extract-rootfs] Installing ${#ordered[@]} CRUX packages into ${OUTPUT_DIR_ABS}..."
    local count=0
    for pkg in "${ordered[@]}"; do
        count=$((count + 1))
        name="$(pkg_name_from_file "$pkg")"
        printf '  [%3d/%3d] %s\n' "$count" "${#ordered[@]}" "$(basename "$pkg")"
        case "$installer" in
            kpm)
                "$KPM_BIN" --config "$TMP_KPM_INI" install "$pkg" >/dev/null
                ;;
            pkgadd)
                pkgadd -r "$OUTPUT_DIR_ABS" "$pkg"
                ;;
            bsdtar)
                install_pkg_bsdtar "$pkg" "$OUTPUT_DIR_ABS"
                ;;
            *)
                echo "extract-rootfs.sh: error: unsupported installer mode: ${installer}" >&2
                exit 2
                ;;
        esac
    done

    chmod 0644 "${OUTPUT_DIR_ABS}/var/lib/pkg/db"
    echo "[extract-rootfs] Installed ${count} packages."
}

# --- Main dispatch ---
if [[ -n "$ROOTFS_TAR" ]]; then
    echo "[extract-rootfs] Extracting rootfs tarball: ${ROOTFS_TAR}"
    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xpf "$ROOTFS_TAR" -C "$OUTPUT_DIR_ABS"
    else
        tar -xpf "$ROOTFS_TAR" -C "$OUTPUT_DIR_ABS"
    fi
elif [[ -n "$SQUASHFS_PATH" ]]; then
    command -v unsquashfs >/dev/null 2>&1 || {
        echo "extract-rootfs.sh: error: unsquashfs is required for --squashfs" >&2
        exit 1
    }
    echo "[extract-rootfs] Extracting squashfs rootfs: ${SQUASHFS_PATH}"
    unsquashfs -f -d "$OUTPUT_DIR_ABS" "$SQUASHFS_PATH"
elif [[ -n "$PKG_DIR" ]]; then
    install_packages "$PKG_DIR" ""
else
    if [[ -n "$ISO_PATH" ]]; then
        if [[ ! -f "$ISO_PATH" ]]; then
            echo "extract-rootfs.sh: error: ISO file not found: ${ISO_PATH}" >&2
            exit 1
        fi
        verify_sha256 "$ISO_PATH" "$ISO_SHA256"
    else
        download_iso "$ISO_URL"
    fi

    ISO_EXTRACT_DIR="${WORK_DIR_ABS}/iso-contents"
    extract_iso_contents "$ISO_PATH" "$ISO_EXTRACT_DIR"

    if [[ -n "$SAVE_PKGS_DIR" ]]; then
        mkdir -p "$SAVE_PKGS_DIR"
        echo "[extract-rootfs] Saving extracted CRUX core/opt packages into ${SAVE_PKGS_DIR}..."
        cp -f "${ISO_EXTRACT_DIR}/crux/core"/*.pkg.tar.* "$SAVE_PKGS_DIR/" 2>/dev/null || true
        if [[ -d "${ISO_EXTRACT_DIR}/crux/opt" ]]; then
            cp -f "${ISO_EXTRACT_DIR}/crux/opt"/*.pkg.tar.* "$SAVE_PKGS_DIR/" 2>/dev/null || true
        fi
    fi

    install_packages "${ISO_EXTRACT_DIR}/crux/core" "${ISO_EXTRACT_DIR}/crux/opt"

    if [[ -f "${ISO_EXTRACT_DIR}/crux-media" ]]; then
        mkdir -p "${OUTPUT_DIR_ABS}/etc"
        cp -f "${ISO_EXTRACT_DIR}/crux-media" "${OUTPUT_DIR_ABS}/etc/crux-media"
    fi
fi

echo "[extract-rootfs] Base CRUX rootfs prepared at ${OUTPUT_DIR_ABS}"
