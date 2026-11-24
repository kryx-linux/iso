# syntax=docker/dockerfile:1

FROM scratch

ARG ROOTFS_TARBALL=build/crux-rootfs.tar.xz
ARG CRUX_VERSION=3.8
ARG BUILD_DATE=unknown
ARG VCS_REF=unknown

ADD ${ROOTFS_TARBALL} /

LABEL org.opencontainers.image.title="CRUX/KryX Linux Rolling Base Image (Unofficial)" \
      org.opencontainers.image.description="Unofficial automated rolling CRUX/KryX Linux container base image for CI and GitHub Actions with kpm package manager." \
      org.opencontainers.image.url="https://github.com/kryx-linux/image" \
      org.opencontainers.image.source="https://github.com/kryx-linux/image" \
      org.opencontainers.image.vendor="kryx-linux" \
      org.opencontainers.image.version="${CRUX_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later"

ENV PATH="/sbin:/usr/sbin:/opt/sbin:/bin:/usr/bin:/opt/bin" \
    LANG="C.UTF-8" \
    LC_ALL="C.UTF-8" \
    TERM="xterm-256color" \
    SSL_CERT_FILE="/etc/ssl/cert.pem" \
    KPM_CONFIG="/etc/kpm.ini"

WORKDIR /root

CMD ["/bin/bash"]
