# `kryx-linux/iso` — KryX Linux Base Container & Minimal Live ISO Builder

Unified repository for building **both**:
1. **KryX Linux Live / Installer ISO (`kryx-linux-x86_64.iso`)** — minimal, CRUX-inspired, strictly **`kpm`**-driven live image using **CRUX's ISO kernel (`linux-6.18.63`)** + SquashFS/OverlayFS `initramfs` and **GRUB** hybrid BIOS + UEFI boot.
2. **KryX Linux Rolling OCI Base Container (`ghcr.io/kryx-linux/iso:latest`)** & RootFS tarball (`kryx-rootfs-x86_64-rolling.tar.xz`) — automated CI build environment shipping static `kpm`, `kpm-index`, `kryx-src`, `gports`, CRUX multi-call symlinks, and `/etc/kpm/keys/kryx-release.pub`.

## Architecture

- **100% `kpm`-driven (zero `pkgadd`/`pkgmk` install calls):** Both `scripts/mkrootfs.sh` and the live installer (`bin/setup`) install packages via `kpm --root=...`.
- **Pre-configured `/etc/kpm/`:** Ships `/etc/kpm.ini`, `/etc/kpm/kpm.ini`, `/etc/gports/sources.list`, and the official release public key `/etc/kpm/keys/kryx-release.pub` (Key ID `2528a8ef6bb01ca3`, Fingerprint `SHA256:JSio72uwHKPFO8HgwqaTitUg26aaKcZxLlwRHIjtSg8`).
- **CRUX ISO Kernel (`linux-6.18.63`) + Initramfs:** Uses CRUX 3.8 ISO's official [`kernel/linux-6.18.63.config`](kernel/linux-6.18.63.config) + [`kernel/linux-6.18.63.defconfig`](kernel/linux-6.18.63.defconfig) compiled from `cdn.kernel.org` with [`kernel/kryx-live.fragment`](kernel/kryx-live.fragment) (`CONFIG_SQUASHFS` ZSTD/XZ/ZLIB + `CONFIG_OVERLAY_FS` + `CONFIG_EFI_STUB`)—never `prebuiltkernel.org`. Still supports `KERNEL_SOURCE=kpm`, `KERNEL_DIR`, or `KERNEL_TAR` overrides.
- **Guaranteed Core & Essential Packages:** `scripts/build-essential-pkgs.sh` ensures every package listed in [`config/packages.live`](config/packages.live) exists (reusing CRUX 3.8 core/opt seed packages or the `kpm` binary index, and building any missing package from `kryx-linux/{core,opt,contrib,ports}` via `kpm build`), and `scripts/mkrootfs.sh` verifies every critical live binary before packing `live/rootfs.squashfs`.
- **Hybrid BIOS + UEFI GRUB:** Generates `kryx-linux-x86_64.iso` via `grub-mkrescue` / `grub2-mkrescue` + `xorriso` and validates boot records + SquashFS via `scripts/verify-iso.sh`.
- **GitHub Actions CI:**
  - [`.github/workflows/iso.yml`](.github/workflows/iso.yml) — builds static `kpm`/`gports`, base container & RootFS, builds any missing core/essential packages inside the KryX container, compiles & caches CRUX ISO's `linux-6.18.63` kernel, creates & verifies `kryx-linux-x86_64.iso`, and publishes ISO + RootFS + `SHA256SUMS.txt` to GitHub Releases.
  - [`.github/workflows/image.yml`](.github/workflows/image.yml) — fast container-only rebuild & publish to `ghcr.io/kryx-linux/iso`.

## Host Prerequisites

### Fedora
```sh
sudo dnf install -y gcc make bc bison flex perl openssl-devel elfutils-libelf-devel \
  squashfs-tools grub2-tools-extra grub2-efi-x64-modules grub2-pc-modules \
  xorriso mtools busybox cpio gzip zstd libarchive docker qemu-system-x86 edk2-ovmf
```

### CRUX / KryX
```sh
sudo kpm install --deps gcc make bc bison flex perl openssl elfutils \
  squashfs-tools grub2 grub2-efi xorriso mtools busybox cpio gzip zstd libarchive
```

## Building

### 1. Build Static Tools + Base Container Image & Seed Packages
```sh
make kpm
sudo make container-rootfs
make docker
make verify-image
```

### 2. Build `kryx-linux-x86_64.iso` (CRUX ISO Kernel + GRUB BIOS/UEFI)
```sh
# Ensure every core & essential live package is present/built:
./scripts/build-essential-pkgs.sh \
  --ports-dir /usr/ports \
  --seed-pkgs build/local-pkgs \
  --out-dir build/local-pkgs

# Compile CRUX's ISO kernel (can run unprivileged; auto-reuses ../crux-iso/kernel/linux-6.18.63.tar.xz if present):
make kernel

# Build live rootfs (kpm), initramfs, and hybrid BIOS+UEFI GRUB ISO:
sudo make all

# Verify ISO El Torito boot records & SquashFS contents:
make verify-iso
```

### Overriding the Kernel Source (Optional)
```sh
# Use custom kernel package from kpm binary repo or local .pkg.tar.zst:
sudo make all KERNEL_SOURCE=kpm KERNEL_PKG=/path/to/kernel#6.18.64-2.pkg.tar.zst

# Use a local prebuilt kernel directory or tarball:
sudo make all KERNEL_DIR=/path/to/kernel-stage
sudo make all KERNEL_TAR=/path/to/kernel-6.18.63.tar.xz
```

## Testing in QEMU

```sh
# BIOS mode:
make qemu

# UEFI mode (OVMF):
make qemu-uefi

# Full install onto a virtual disk:
qemu-img create -f qcow2 test-disk.qcow2 20G
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
  -bios /usr/share/edk2/ovmf/OVMF_CODE.fd \
  -cdrom kryx-linux-x86_64.iso \
  -drive file=test-disk.qcow2,format=qcow2,if=virtio \
  -boot d
```

Inside the live root TTY:
```sh
cfdisk /dev/vda
mkfs.fat -F32 /dev/vda1 && mkfs.ext4 /dev/vda2
mount /dev/vda2 /mnt && mkdir -p /mnt/boot/efi && mount /dev/vda1 /mnt/boot/efi
setup /mnt
setup-chroot /mnt
```
