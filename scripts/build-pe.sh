#!/usr/bin/env bash
# Build static (CGO_ENABLED=0) pe and pe-index binaries without modifying the source checkout.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PE_SRC=""
PE_REPO="https://github.com/kryx-linux/pe.git"
PE_REF="main"
OUT_DIR="${REPO_ROOT}/build/bin"
PE_VERSION=""
TARGET_ARCH="${GOARCH:-amd64}"
RUN_TESTS=0

usage() {
    cat <<'EOF'
Usage: scripts/build-pe.sh [options]

Options:
  --src <dir>        Path to a local pe Git checkout (auto-detects ../pe if present)
  --repo <url>       Git URL to clone when --src is omitted (default: https://github.com/kryx-linux/pe.git)
  --ref <ref>        Git branch, tag, or commit when cloning (default: main)
  --out <dir>        Output directory for static binaries (default: build/bin)
  --version <ver>    Version string injected into pe binary
  --arch <goarch>    Target GOARCH (default: amd64)
  --test             Run `go test ./...` before building
  -h, --help         Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            PE_SRC="$2"
            shift 2
            ;;
        --repo)
            PE_REPO="$2"
            shift 2
            ;;
        --ref)
            PE_REF="$2"
            shift 2
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --version)
            PE_VERSION="$2"
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
            echo "build-pe.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

command -v go >/dev/null 2>&1 || {
    echo "build-pe.sh: error: 'go' is required to build pe and pe-index" >&2
    exit 1
}

mkdir -p "$OUT_DIR"
OUT_DIR_ABS="$(cd "$OUT_DIR" && pwd)"

TMP_CLONE=""
cleanup() {
    if [[ -n "$TMP_CLONE" && -d "$TMP_CLONE" ]]; then
        rm -rf "$TMP_CLONE"
    fi
}
trap cleanup EXIT

if [[ -z "$PE_SRC" ]]; then
    if [[ -f "${REPO_ROOT}/../pe/go.mod" ]]; then
        PE_SRC="$(cd "${REPO_ROOT}/../pe" && pwd)"
        echo "[build-pe] Using local pe checkout: ${PE_SRC}"
    else
        command -v git >/dev/null 2>&1 || {
            echo "build-pe.sh: error: 'git' is required to clone ${PE_REPO}" >&2
            exit 1
        }
        TMP_CLONE="$(mktemp -d "${TMPDIR:-/tmp}/pe-src.XXXXXX")"
        echo "[build-pe] Cloning ${PE_REPO} (${PE_REF})..."
        git clone --depth 1 --branch "$PE_REF" "$PE_REPO" "$TMP_CLONE" 2>/dev/null || {
            git clone "$PE_REPO" "$TMP_CLONE"
            git -C "$TMP_CLONE" checkout "$PE_REF"
        }
        PE_SRC="$TMP_CLONE"
    fi
else
    PE_SRC="$(cd "$PE_SRC" && pwd)"
fi

if [[ ! -f "${PE_SRC}/go.mod" ]]; then
    echo "build-pe.sh: error: ${PE_SRC} does not appear to be a valid pe Go repository" >&2
    exit 1
fi

if [[ -z "$PE_VERSION" ]]; then
    if git -C "$PE_SRC" rev-parse --git-dir >/dev/null 2>&1; then
        PE_VERSION="$(git -C "$PE_SRC" describe --tags --always 2>/dev/null || echo "0.1.0")"
    else
        PE_VERSION="0.1.0"
    fi
fi

LDFLAGS="-s -w -X github.com/kryx-linux/pe/internal/cli.Version=${PE_VERSION}"

if [[ "$RUN_TESTS" -eq 1 ]]; then
    echo "[build-pe] Running go test ./..."
    (cd "$PE_SRC" && go test ./...)
fi

echo "[build-pe] Building static pe, pe-index, and kryx-src (version=${PE_VERSION}, GOARCH=${TARGET_ARCH})..."
(
    cd "$PE_SRC"
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "${OUT_DIR_ABS}/pe" ./cmd/pe
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "${OUT_DIR_ABS}/pe-index" ./cmd/pe-index
    CGO_ENABLED=0 GOOS=linux GOARCH="$TARGET_ARCH" \
        go build -trimpath -ldflags "$LDFLAGS" -o "${OUT_DIR_ABS}/kryx-src" ./cmd/kryx-src
)

chmod 0755 "${OUT_DIR_ABS}/pe" "${OUT_DIR_ABS}/pe-index" "${OUT_DIR_ABS}/kryx-src"

echo "[build-pe] Built:"
"${OUT_DIR_ABS}/pe" --version
"${OUT_DIR_ABS}/kryx-src" --version
ls -lh "${OUT_DIR_ABS}/pe" "${OUT_DIR_ABS}/pe-index" "${OUT_DIR_ABS}/kryx-src"
