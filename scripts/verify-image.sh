#!/usr/bin/env bash
# Run post-build verification checks inside the built CRUX Linux container image.
set -euo pipefail

IMAGE="${1:-ghcr.io/crux-rolling/image:latest}"

command -v docker >/dev/null 2>&1 || {
    echo "verify-image.sh: error: 'docker' is required to verify container image ${IMAGE}" >&2
    exit 1
}

echo "[verify-image] Running verification suite against ${IMAGE}..."

docker run --rm "$IMAGE" /bin/bash -euo pipefail -c '
echo "=== 1. OS Identity & Environment ==="
cat /etc/os-release
crux
echo "PATH=${PATH}"
echo "LANG=${LANG:-unset} LC_ALL=${LC_ALL:-unset}"
echo "SSL_CERT_FILE=${SSL_CERT_FILE:-unset} PE_CONFIG=${PE_CONFIG:-unset}"

echo "=== 2. Package Database & pe Checks ==="
test -s /var/lib/pkg/db
test -s /etc/pe.ini
grep -q "ports_dir = /usr/ports" /etc/pe.ini
grep -q "repository = ezke5/packages" /etc/pe.ini
grep -q "tag = rolling-x86_64" /etc/pe.ini

pe --version
INSTALLED_COUNT="$(pe list | wc -l)"
echo "Installed packages in /var/lib/pkg/db: ${INSTALLED_COUNT}"
test "${INSTALLED_COUNT}" -gt 20

PORTS_COUNT="$(pe list --ports | wc -l)"
echo "Available ports in /usr/ports: ${PORTS_COUNT}"
test "${PORTS_COUNT}" -gt 50
pe list --ports | grep -q "^core/bash$"
pe list --ports | grep -q "^core/pkgutils$"

pe-index --help >/dev/null 2>&1 || pe-index --help 2>&1 | grep -q "Usage of pe-index"

echo "=== 3. Network & TLS Defaults ==="
test -s /etc/ssl/cert.pem
grep -q "BEGIN CERTIFICATE" /etc/ssl/cert.pem
grep -q "^hosts:.*dns" /etc/nsswitch.conf
grep -q "localhost" /etc/hosts

echo "=== 4. Toolchain & Archive Smoke Test ==="
gcc --version | head -n 1
make --version | head -n 1
bsdtar --version
tar --version | head -n 1
xz --version | head -n 1
zstd --version
curl --version | head -n 1
pkginfo -i | head -n 5

TMPDIR_TEST="$(mktemp -d /tmp/crux-verify.XXXXXX)"
trap "rm -rf \"${TMPDIR_TEST}\"" EXIT

cat > "${TMPDIR_TEST}/hello.c" <<EOF
#include <stdio.h>
int main(void) {
    puts("crux-rolling-ok");
    return 0;
}
EOF

gcc -O2 -Wall -Werror -o "${TMPDIR_TEST}/hello" "${TMPDIR_TEST}/hello.c"
OUT="$("${TMPDIR_TEST}/hello")"
test "${OUT}" = "crux-rolling-ok"

bsdtar --format=gnutar --zstd -cf "${TMPDIR_TEST}/smoke#1.0-1.pkg.tar.zst" -C "${TMPDIR_TEST}" hello
bsdtar -tf "${TMPDIR_TEST}/smoke#1.0-1.pkg.tar.zst" | grep -qx "hello"

echo "=== All CRUX image verification checks passed! ==="
'
