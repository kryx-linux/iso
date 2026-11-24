#!/usr/bin/env bash
# Build static (CGO_ENABLED=0) kpm, kpm-index, and kryx-src binaries without modifying the source checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KPM_SRC=""
KPM_REPO="https://github.com/kryx-linux/kpm.git"
KPM_REF="main"
GPORTS_SRC=""
GPORTS_REPO="https://github.com/kryx-linux/gports.git"
GPORTS_REF="main"
BUILD_GPORTS=1
OUT_DIR="${REPO_ROOT}/build/bin"
KPM_VERSION=""
TARGET_ARCH="${GOARCH:-amd64}"
RUN_TESTS=0

usage() {
    cat <<'EOF'
Usage: scripts/build-kpm.sh [options]

Options:
  --src <dir>          Path to a local kpm Git checkout (auto-detects ../kpm if present)
  --repo <url>         Git URL to clone when --src is omitted (default: https://github.com/kryx-linux/kpm.git)
  --ref <ref>          Git branch, tag, or commit when cloning (default: main)
  --gports-src <dir>   Path to a local gports Git checkout (auto-detects ../gports if present)
  --gports-repo <url>  Git URL to clone gports when --gports-src is omitted
  --gports-ref <ref>   Git ref for gports (default: main)
  --no-gports          Skip building static gports binary
  --out <dir>          Output directory for static binaries (default: build/bin)
  --version <ver>      Version string injected into kpm binary
  --arch <goarch>      Target GOARCH (default: amd64)
  --test               Run `go test ./...` before building
  -h, --help           Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            KPM_SRC="$2"
            shift 2
            ;;
        --repo)
            KPM_REPO="$2"
            shift 2
            ;;
        --ref)
            KPM_REF="$2"
            shift 2
            ;;
        --gports-src)
            GPORTS_SRC="$2"
            shift 2
            ;;
        --gports-repo)
            GPORTS_REPO="$2"
            shift 2
            ;;
        --gports-ref)
            GPORTS_REF="$2"
            shift 2
            ;;
        --no-gports)
            BUILD_GPORTS=0
            shift
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --version)
            KPM_VERSION="$2"
            shift 2
            ;;
        --arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        --test)
            RUN_TESTS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "build-kpm.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command -v go >/dev/null 2>&1 || {
    echo "build-kpm.sh: error: 'go' is required to build kpm, kpm-index, and kryx-src" >&2
    exit 1
}

mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"

TMP_CLONE=""
TMP_GPORTS_CLONE=""
cleanup() {
    if [[ -n "$TMP_CLONE" && -d "$TMP_CLONE" ]]; then
        rm -rf "$TMP_CLONE"
    fi
    if [[ -n "$TMP_GPORTS_CLONE" && -d "$TMP_GPORTS_CLONE" ]]; then
        rm -rf "$TMP_GPORTS_CLONE"
    fi
}
trap cleanup EXIT

if [[ -z "$KPM_SRC" ]]; then
    if [[ -f "${REPO_ROOT}/../kpm/go.mod" ]]; then
        KPM_SRC="$(cd "${REPO_ROOT}/../kpm" && pwd)"
        echo "[build-kpm] Using local kpm checkout: ${KPM_SRC}"
    else
        command -v git >/dev/null 2>&1 || {
            echo "build-kpm.sh: error: 'git' is required to clone ${KPM_REPO}" >&2
            exit 1
        }
        TMP_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/kpm-src.XXXXXX")"
        echo "[build-kpm] Cloning ${KPM_REPO} (${KPM_REF})..."
        git clone --depth 1 --branch "$KPM_REF" "$KPM_REPO" "$TMP_CLONE" 2>/dev/null || {
            git clone "$KPM_REPO" "$TMP_CLONE"
            git -C "$TMP_CLONE" checkout "$KPM_REF"
        }
        KPM_SRC="$TMP_CLONE"
    fi
else
    KPM_SRC="$(cd "$KPM_SRC" && pwd)"
fi

if [[ ! -f "${KPM_SRC}/go.mod" ]]; then
    echo "build-kpm.sh: error: ${KPM_SRC} does not appear to be a valid kpm Go repository" >&2
    exit 1
fi

if [[ -z "$KPM_VERSION" ]]; then
    if git -C "$KPM_SRC" rev-parse --git-dir >/dev/null 2>&1; then
        KPM_VERSION="$(git -C "$KPM_SRC" describe --tags --always 2>/dev/null || echo "0.6.0")"
    else
        KPM_VERSION="0.6.0"
    fi
fi

LDFLAGS="-s -w -X github.com/kryx-linux/kpm/internal/cli.Version=${KPM_VERSION}"

if [[ "$RUN_TESTS" -eq 1 ]]; then
    echo "[build-kpm] Running go test ./..."
    (cd "$KPM_SRC" && CGO_ENABLED=0 go test ./...)
fi

echo "[build-kpm] Building static kpm, kpm-index, and kryx-src (version=${KPM_VERSION}, GOARCH=${TARGET_ARCH})..."
(
    cd "$KPM_SRC"
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "${OUT_DIR_ABS}/kpm" ./cmd/kpm
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "${OUT_DIR_ABS}/kpm-index" ./cmd/kpm-index
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "${OUT_DIR_ABS}/kryx-src" ./cmd/kryx-src
)

chmod 0755 "${OUT_DIR_ABS}/kpm" "${OUT_DIR_ABS}/kpm-index" "${OUT_DIR_ABS}/kryx-src"

if [[ "$BUILD_GPORTS" -eq 1 ]]; then
    if [[ -z "$GPORTS_SRC" && -f "${REPO_ROOT}/../gports/go.mod" ]]; then
        GPORTS_SRC="$(cd "${REPO_ROOT}/../gports" && pwd)"
        echo "[build-kpm] Using local gports checkout: ${GPORTS_SRC}"
    elif [[ -z "$GPORTS_SRC" ]]; then
        if command -v git >/dev/null 2>&1; then
            TMP_GPORTS_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/gports-src.XXXXXX")"
            echo "[build-kpm] Cloning ${GPORTS_REPO} (${GPORTS_REF})..."
            if git clone --depth 1 --branch "$GPORTS_REF" "$GPORTS_REPO" "$TMP_GPORTS_CLONE" 2>/dev/null; then
                GPORTS_SRC="$TMP_GPORTS_CLONE"
            else
                echo "[build-kpm] Warning: failed to clone ${GPORTS_REPO}; skipping gports build" >&2
            fi
        fi
    else
        GPORTS_SRC="$(cd "$GPORTS_SRC" && pwd)"
    fi

    if [[ -n "$GPORTS_SRC" && -f "${GPORTS_SRC}/go.mod" ]]; then
        GPORTS_VER="$(git -C "$GPORTS_SRC" describe --tags --always 2>/dev/null || echo "1.3.2")"
        MODFLAG=""
        [[ -d "${GPORTS_SRC}/vendor" ]] && MODFLAG="-mod=vendor"
        if [[ "$RUN_TESTS" -eq 1 ]]; then
            echo "[build-kpm] Running gports go test ./..."
            (cd "$GPORTS_SRC" && CGO_ENABLED=0 go test ${MODFLAG} ./...)
        fi
        echo "[build-kpm] Building static gports (version=${GPORTS_VER}, GOARCH=${TARGET_ARCH})..."
        (
            cd "$GPORTS_SRC"
            CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
                go build ${MODFLAG} -trimpath -ldflags "-s -w -X main.version=${GPORTS_VER}" \
                -o "${OUT_DIR_ABS}/gports" ./cmd/gports
        )
        chmod 0755 "${OUT_DIR_ABS}/gports"
    fi
fi

echo "[build-kpm] Built:"
"${OUT_DIR_ABS}/kpm" --version
"${OUT_DIR_ABS}/kryx-src" --version
[[ -x "${OUT_DIR_ABS}/gports" ]] && "${OUT_DIR_ABS}/gports" --version || true
ls -lh "${OUT_DIR_ABS}"/
