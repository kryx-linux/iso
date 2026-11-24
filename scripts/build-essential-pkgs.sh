#!/usr/bin/env bash
# scripts/build-essential-pkgs.sh - Guarantee every core & necessary live ISO package
# listed in config/packages.live exists as a built .pkg.tar.* archive.
#
# Checks (in order):
#   1. --seed-pkgs <dir>  (e.g., extracted CRUX 3.8 core/opt packages or cached local builds)
#   2. kpm remote binary index (unless --no-sync or --rebuild-all)
#   3. Compiles any missing package directly from --ports-dir using `kpm build`!
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PKG_LIST="${REPO_ROOT}/config/packages.live"
PORTS_DIR="/usr/ports"
SEED_DIR=""
OUT_DIR="${REPO_ROOT}/build/local-pkgs"
WORK_DIR="${REPO_ROOT}/build/pkg-work"
KPM_BIN="$(command -v kpm 2>/dev/null || echo /usr/bin/kpm)"
JOBS="$(nproc 2>/dev/null || echo 2)"
NO_SYNC=0
REBUILD_ALL=0
IGNORE_FOOTPRINT=1
IGNORE_MD5SUM=0

usage() {
    cat <<'EOF'
Usage: scripts/build-essential-pkgs.sh [options]

Ensures every core & necessary live package in config/packages.live is built
into --out-dir as a .pkg.tar.* archive before ISO rootfs assembly.

Options:
  --pkg-list <file>     Package list file (default: config/packages.live)
  --ports-dir <dir>     Ports tree containing core/, opt/, contrib/, rolling/ (default: /usr/ports)
  --seed-pkgs <dir>     Optional directory of prebuilt .pkg.tar.* packages to reuse
  --out-dir <dir>       Output directory for collected/built .pkg.tar.* archives (default: build/local-pkgs)
  --work-dir <dir>      Temporary kpm build work directory (default: build/pkg-work)
  --kpm-bin <path>      Path to kpm binary (default: PATH / /usr/bin/kpm)
  --jobs <N>            Parallel build jobs (default: nproc)
  --no-sync             Do not query remote kpm binary index
  --rebuild-all         Build every listed package from source even if present in seed/index
  --strict-footprint    Enforce strict .footprint checks during source builds
  --ignore-md5sum       Skip .md5sum verification during source builds
  -h, --help            Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pkg-list)         PKG_LIST="$2"; shift 2 ;;
        --ports-dir)        PORTS_DIR="$2"; shift 2 ;;
        --seed-pkgs)        SEED_DIR="$2"; shift 2 ;;
        --out-dir)          OUT_DIR="$2"; shift 2 ;;
        --work-dir)         WORK_DIR="$2"; shift 2 ;;
        --kpm-bin)          KPM_BIN="$2"; shift 2 ;;
        --jobs)             JOBS="$2"; shift 2 ;;
        --no-sync)          NO_SYNC=1; shift ;;
        --rebuild-all)      REBUILD_ALL=1; shift ;;
        --strict-footprint) IGNORE_FOOTPRINT=0; shift ;;
        --ignore-md5sum)    IGNORE_MD5SUM=1; shift ;;
        -h|--help)          usage; exit 0 ;;
        *)                  echo "build-essential-pkgs.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ ! -f "$PKG_LIST" ]]; then
    echo "build-essential-pkgs.sh: error: package list not found: ${PKG_LIST}" >&2
    exit 1
fi
if [[ ! -x "$KPM_BIN" ]]; then
    echo "build-essential-pkgs.sh: error: kpm binary not found at ${KPM_BIN}" >&2
    exit 1
fi

mkdir -p "$OUT_DIR" "$WORK_DIR/cache" "$WORK_DIR/sources" "$WORK_DIR/work"
OUT_ABS="$(cd "$OUT_DIR" && pwd)"
WORK_ABS="$(cd "$WORK_DIR" && pwd)"

KPM_CONF="${WORK_ABS}/kpm.essential.ini"
cat > "$KPM_CONF" <<EOF
[paths]
root = /
ports_dir = ${PORTS_DIR}
collections = rolling, core, opt, xorg, contrib
cache_dir = ${WORK_ABS}/cache
source_cache = ${WORK_ABS}/sources
package_dir = ${OUT_ABS}
work_dir = ${WORK_ABS}/work
pkgadd_conf = /etc/pkgadd.conf
keys_dir = /etc/kpm/keys

[repo]
repository = kryx-linux/ports
tag = rolling-x86_64
arch = x86_64
index_url = https://github.com/kryx-linux/ports/releases/download/rolling-x86_64/index.json
verify_index_signature = false
timeout_seconds = 180

[build]
jobs = ${JOBS}
cflags = -O2 -march=x86-64 -pipe
cxxflags = -O2 -march=x86-64 -pipe
compression = zst
download_sources = true
strip = true
compress_manpages = true
ignore_footprint = $( [[ "$IGNORE_FOOTPRINT" -eq 1 ]] && echo true || echo false )
ignore_new = true
ignore_md5sum = $( [[ "$IGNORE_MD5SUM" -eq 1 ]] && echo true || echo false )
ignore_signature = true
keep_work = false
download_prog = curl

[ui]
color = never
EOF

REMOTE_INDEX=""
if [[ "$NO_SYNC" -eq 0 && "$REBUILD_ALL" -eq 0 ]]; then
    echo "[build-essential-pkgs] Syncing remote KryX binary index..."
    if "$KPM_BIN" --config "$KPM_CONF" sync; then
        REMOTE_INDEX="$("$KPM_BIN" --config "$KPM_CONF" list --binaries | awk '{print $1}')"
    else
        echo "[build-essential-pkgs] Warning: remote kpm sync failed; relying on seed packages and local port builds" >&2
    fi
fi

find_pkg_archive() {
    local dir="$1"
    local pkg="$2"
    [[ -d "$dir" ]] || return 1
    shopt -s nullglob
    local matches=("${dir}/${pkg}"#*.pkg.tar.*)
    if [[ "${#matches[@]}" -gt 0 ]]; then
        printf '%s\n' "${matches[0]}"
        return 0
    fi
    return 1
}

mapfile -t REQUIRED_PKGS < <(grep -vE '^\s*(#|$)' "$PKG_LIST")
echo "[build-essential-pkgs] Auditing ${#REQUIRED_PKGS[@]} core/essential live packages..."

TO_BUILD=()
REUSED_SEED=0
AVAIL_REMOTE=0

for pkg in "${REQUIRED_PKGS[@]}"; do
    # kpm and gports are built as static Go binaries via build-kpm.sh if absent as packages.
    if [[ "$REBUILD_ALL" -eq 0 ]]; then
        if archive="$(find_pkg_archive "$OUT_ABS" "$pkg")"; then
            echo "  [cached] $(basename "$archive")"
            REUSED_SEED=$((REUSED_SEED + 1))
            continue
        fi
        if [[ -n "$SEED_DIR" ]] && archive="$(find_pkg_archive "$SEED_DIR" "$pkg")"; then
            cp -f "$archive" "${OUT_ABS}/"
            echo "  [seed]   $(basename "$archive")"
            REUSED_SEED=$((REUSED_SEED + 1))
            continue
        fi
        if [[ -n "$REMOTE_INDEX" ]] && grep -qx "$pkg" <<< "$REMOTE_INDEX"; then
            echo "  [remote] ${pkg} (available in kpm binary index)"
            AVAIL_REMOTE=$((AVAIL_REMOTE + 1))
            continue
        fi
    fi

    # Skip source-building kpm when the static binary is already staged in build/bin/
    if [[ "$pkg" == "kpm" && -x "${REPO_ROOT}/build/bin/kpm" ]]; then
        echo "  [static] kpm (staged at build/bin/kpm)"
        continue
    fi

    TO_BUILD+=("$pkg")
done

echo "[build-essential-pkgs] Summary: ${REUSED_SEED} seeded/cached, ${AVAIL_REMOTE} in remote index, ${#TO_BUILD[@]} to build from ports."

FAILED=()
for pkg in "${TO_BUILD[@]}"; do
    echo "[build-essential-pkgs] Building missing essential package '${pkg}' from ${PORTS_DIR}..."
    BUILD_ARGS=(--deps --force)
    [[ "$IGNORE_FOOTPRINT" -eq 1 ]] && BUILD_ARGS+=(--ignore-footprint)
    [[ "$IGNORE_MD5SUM" -eq 1 ]] && BUILD_ARGS+=(--ignore-md5sum)

    if "$KPM_BIN" --config "$KPM_CONF" build "${BUILD_ARGS[@]}" "$pkg"; then
        if archive="$(find_pkg_archive "$OUT_ABS" "$pkg")"; then
            echo "  [built]  $(basename "$archive")"
        else
            echo "  [ERROR]  kpm build succeeded for '${pkg}', but no archive found in ${OUT_ABS}" >&2
            FAILED+=("$pkg")
        fi
    else
        echo "  [ERROR]  failed to build essential package '${pkg}'" >&2
        FAILED+=("$pkg")
    fi
done

if [[ "${#FAILED[@]}" -gt 0 ]]; then
    echo "build-essential-pkgs.sh: ERROR: failed to resolve/build essential package(s): ${FAILED[*]}" >&2
    exit 1
fi

echo "[build-essential-pkgs] All ${#REQUIRED_PKGS[@]} core & essential live packages verified ready in ${OUT_ABS}."
