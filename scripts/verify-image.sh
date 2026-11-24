#!/usr/bin/env bash
# Run post-build verification checks inside the built CRUX Linux container image.
set -euo pipefail

IMAGE="${1:-ghcr.io/kryx-linux/iso:latest}"

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
echo "SSL_CERT_FILE=${SSL_CERT_FILE:-unset} KPM_CONFIG=${KPM_CONFIG:-unset}"

echo "=== 2. Package Database & kpm Checks ==="
test -s /var/lib/pkg/db
test -s /etc/kpm.ini
grep -q "ports_dir = /usr/ports" /etc/kpm.ini
grep -q "repository = kryx-linux/ports" /etc/kpm.ini
grep -q "tag = rolling-x86_64" /etc/kpm.ini

kpm --version
INSTALLED_LIST="$(kpm list)"
INSTALLED_COUNT="$(printf '%s\n' "${INSTALLED_LIST}" | wc -l)"
echo "Installed packages in /var/lib/pkg/db: ${INSTALLED_COUNT}"
test "${INSTALLED_COUNT}" -gt 20

PORTS_LIST="$(kpm list --ports)"
PORTS_COUNT="$(printf '%s\n' "${PORTS_LIST}" | wc -l)"
echo "Available ports in /usr/ports: ${PORTS_COUNT}"
test "${PORTS_COUNT}" -gt 50
grep -q "^core/bash$" <<< "${PORTS_LIST}"
grep -q "^core/pkgutils$" <<< "${PORTS_LIST}"

KPM_INDEX_HELP="$(kpm-index --help 2>&1 || true)"
grep -q "Usage of kpm-index" <<< "${KPM_INDEX_HELP}"

for link in pkgadd pkgrm pkginfo pkgmk ports rejmerge; do
    "${link}" --version
done

if [ -x /usr/bin/kryx-src ]; then
    kryx-src --version
fi
if [ -x /usr/bin/gports ]; then
    gports --version
fi
test -s /etc/kpm/keys/kryx-release.pub
grep -q "2528a8ef6bb01ca3" /etc/kpm/keys/kryx-release.pub

echo "=== 3. Network & TLS Defaults ==="
test -s /etc/ssl/cert.pem
grep -q "BEGIN CERTIFICATE" /etc/ssl/cert.pem
grep -q "^hosts:.*dns" /etc/nsswitch.conf
grep -q "localhost" /etc/hosts

echo "=== 4. Toolchain & Archive Smoke Test ==="
show_head() {
    local n="$1"
    shift
    "$@" | awk -v n="$n" "NR <= n { print }"
}

show_head 1 gcc --version
show_head 1 make --version
bsdtar --version
show_head 1 tar --version
show_head 1 xz --version
zstd --version
show_head 1 curl --version
show_head 5 pkginfo -i

TMPDIR_TEST="$(mktemp -d /tmp/crux-verify.XXXXXX)"
trap "rm -rf \"${TMPDIR_TEST}\"" EXIT

cat > "${TMPDIR_TEST}/hello.c" <<EOF
#include <stdio.h>
int main(void) {
    puts("kryx-linux-ok");
    return 0;
}
EOF

gcc -O2 -Wall -Werror -o "${TMPDIR_TEST}/hello" "${TMPDIR_TEST}/hello.c"
OUT="$("${TMPDIR_TEST}/hello")"
test "${OUT}" = "kryx-linux-ok"

bsdtar --format=gnutar --zstd -cf "${TMPDIR_TEST}/smoke#1.0-1.pkg.tar.zst" -C "${TMPDIR_TEST}" hello
ARCHIVE_LIST="$(bsdtar -tf "${TMPDIR_TEST}/smoke#1.0-1.pkg.tar.zst")"
grep -qx "hello" <<< "${ARCHIVE_LIST}"

echo "=== All CRUX image verification checks passed! ==="
'
