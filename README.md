# kryx-linux/image

Automated, reproducible **CRUX Linux** base container image tailored for GitHub Actions and CI build environments, preconfigured with the standalone [`pe`](https://github.com/kryx-linux/pe) binary-first CRUX package manager.

> **Unofficial Rolling Build Notice**
>
> This repository and the published container images are **unofficial, community-maintained rolling builds** of CRUX Linux. They are not affiliated with, endorsed by, or maintained by the upstream CRUX Linux project (`https://crux.nu`). All upstream CRUX packages, build scripts, and tools retain their original upstream licenses (primarily GNU GPL).

## Features

- **Authentic CRUX Base Rootfs**: Built directly from CRUX `core` binary packages (`/crux/core/*.pkg.tar.*`) extracted from the official CRUX ISO—not from the stripped live-installer `rootfs.tar.xz`—so `/var/lib/pkg/db`, headers, and build toolchains are intact.
- **Curated CI Profile**: Excludes bare-metal/hardware/init-only packages (see `config/core-exclude.txt`) while keeping full C/C++/Python/CMake/Meson/Ninja/archive/networking toolchains (`gcc`, `binutils`, `make`, `cmake`, `meson`, `ninja`, `python3`, `perl`, `curl`, `openssl`, `ca-certificates`, `libarchive`/`bsdtar`, `xz`, `zstd`, `pkgutils`, `ports`, `httpup`, `rsync`, `openssh`). Pass `FULL_CORE=1` or `--full-core` to include every `core` package.
- **`pe` Ready Out of the Box**: Includes static `pe` and `pe-index` binaries in `/usr/bin`, `/etc/pe.ini` pointing to `/usr/ports` and `kryx-linux/ports` (`rolling-x86_64`), and a snapshot of `/usr/ports/core`.
- **Lean `FROM scratch` Image**: Single-layer rootfs import with clean OCI labels, `C.UTF-8` locale, `SSL_CERT_FILE=/etc/ssl/cert.pem`, and standard CRUX `PATH`.

## Container Images & Tags

Primary registry (GHCR):

```sh
docker pull ghcr.io/kryx-linux/image:latest
docker pull ghcr.io/kryx-linux/image:rolling
docker pull ghcr.io/kryx-linux/image:3.8
```

Optional mirror (Docker Hub, published when registry secrets are configured):

```sh
docker pull kryx-linux/image:latest
```

Published tags on `main` / scheduled builds:
- `latest`, `rolling` — latest automated rolling build
- `3.8` — latest build for CRUX 3.8
- `3.8-YYYYMMDD` — dated rolling snapshot
- `sha-<commit>` — exact repository commit

## Quick Usage

```sh
# Start an interactive CRUX CI container
docker run --rm -it ghcr.io/kryx-linux/image:latest

# Inside the container:
crux
pe list
pe list --ports
pe sync
pe search zlib
```

Using in GitHub Actions:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/kryx-linux/image:latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          pe --version
          pe list --ports | head
          gcc --version
```

## Architecture & Repository Layout

```text
.
├── .github/workflows/image.yml  # Weekly rolling build, verification, and registry push
├── config/
│   ├── core-exclude.txt         # Curated bare-metal/init exclusions for CI containers
│   └── pe.ini                   # Default /etc/pe.ini installed into the image
├── scripts/
│   ├── build-pe.sh              # Builds static (CGO_ENABLED=0) pe & pe-index binaries
│   ├── extract-rootfs.sh        # Extracts CRUX ISO and installs core packages into rootfs
│   ├── customize-rootfs.sh      # Applies CI defaults, pe, /usr/ports/core, and packs tarball
│   └── verify-image.sh          # Post-build container smoke tests
├── Dockerfile                   # Lean FROM scratch image importing build/crux-rootfs.tar.xz
├── Makefile                     # Local and CI build entrypoint
└── LICENSE                      # GNU General Public License v3
```

## Building Locally

### Prerequisites

- Linux x86_64 host with `bash`, `go` (1.24+), `bsdtar` (or `xorriso`/`7z`), `tar`, `xz`, `zstd`, `curl`, `git`, and `docker`.
- Root privileges (e.g., `sudo`) are recommended for `extract-rootfs.sh` and `customize-rootfs.sh` so package ownership, permissions, and setuid bits are preserved identically to CRUX `pkgadd`.

### Build from Upstream Rolling CRUX ISO

```sh
# 1. Build static pe & pe-index binaries
make pe

# 2. Extract and customize the CRUX rootfs tarball (run as root for faithful ownership/modes)
sudo make rootfs

# 3. Build and verify the Docker image
make docker
make verify
```

### Common Overrides

```sh
# Use a local CRUX ISO and local sibling checkouts of pe and core ports
make pe PE_SRC=../pe
sudo make rootfs \
  ISO_PATH=/path/to/crux-3.8-updated.iso \
  ISO_SHA256=<expected-sha256> \
  CORE_PORTS_SRC=../core

# Include every package in CRUX core (disable config/core-exclude.txt)
sudo make rootfs FULL_CORE=1

# Include additional packages from /crux/opt on the ISO
sudo make rootfs INCLUDE_OPT="fakeroot,unzip,zip"
```

## CI Automation & Registry Secrets

The GitHub Actions workflow (`.github/workflows/image.yml`) runs:
- **Weekly** on Sunday (`06:00 UTC`, after upstream CRUX weekly ISO builds)
- **On push** to `main` and on **pull requests** (PRs build and verify without pushing)
- **Manually** via `workflow_dispatch` with overridable `iso_url`, `iso_sha256`, `crux_version`, `pe_ref`, `full_core`, and `push_image` inputs.

### Registry Configuration

- **GHCR (`ghcr.io/kryx-linux/image`)**: Authenticated automatically with `GITHUB_TOKEN` (`packages: write`). No extra secrets are required.
- **Docker Hub (`kryx-linux/image`)**: Conditionally enabled only when both repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are configured.

## Licensing

- Build scripts, Dockerfile, configuration, and CI workflows in this repository are licensed under the **GNU General Public License v3.0 or later** (see [LICENSE](LICENSE)).
- Upstream CRUX Linux (`https://crux.nu`), `pkgutils`, `ports`, `httpup`, and `kryx-linux/pe` are free and open-source software distributed under their respective upstream GPL / open-source licenses.
