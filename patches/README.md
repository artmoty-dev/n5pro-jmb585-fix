# JMB585 32-bit DMA Kernel Patch

## What This Does

Forces 32-bit DMA addressing for the JMicron JMB582/JMB585 SATA controllers.
These controllers advertise 64-bit DMA support (S64A bit in AHCI CAP register)
but their implementation is broken — DMA transfers targeting addresses above
4GB silently corrupt data by writing to incorrect memory locations.

## Why This Works

The `amd_iommu=pgtbl_v2` kernel parameter constrains the *entire platform's* IOMMU
to 48-bit page tables. This patch instead targets the *specific controller* that
can't handle 64-bit DMA, using the same `AHCI_HFLAG_32BIT_ONLY` mechanism the
kernel already uses for other broken controllers (ASMedia ASM1061, ATI SB600).

## Files

| File | Purpose |
|------|---------|
| `0001-ahci-force-32bit-dma-for-jmb585.patch` | Kernel patch (commit message format, for upstream submission) |
| `build-rpm.sh` | Automated build script with verification |
| `README.md` | This file |

## Build & Test Instructions

**Important:** On Fedora, `CONFIG_SATA_AHCI=y` (built into the kernel, not a
loadable module). This means we must build a full custom kernel — a module-only
rebuild is not possible.

The build produces a kernel that installs *alongside* your existing one. GRUB
gives you a menu to choose which kernel to boot. Your stock kernel is never
modified.

### Prerequisites

```bash
sudo dnf install rpm-build kernel-devel-$(uname -r) gcc make \
  bison flex elfutils-libelf-devel openssl-devel perl-generators \
  python3-devel ncurses-devel bc rsync dwarves
```

### Step 1: Get the kernel source

```bash
cd ~
dnf download --source kernel-$(uname -r | sed 's/.fc.*//').fc$(rpm -E %fedora)
rpm -ivh kernel-*.src.rpm
```

### Step 2: Configure, patch, and build

```bash
cd ~/projects/N5Pro/patches
./build-rpm.sh --build
```

This will:
1. Extract the kernel source to `~/kernel-build/`
2. Apply the JMB585 patch to `drivers/ata/ahci.c`
3. Verify the patch was applied correctly
4. Configure the kernel (based on your running config, with debug info disabled)
5. Build `bzImage` + all modules (~1-2 hours)
6. Verify the build output contains the JMB585 symbols

You can also run steps individually:
```bash
./build-rpm.sh --configure-only   # Steps 1-4 only (no compile)
./build-rpm.sh --verify           # Step 6 only (check existing build)
./build-rpm.sh --clean            # Remove ~/kernel-build/ entirely
```

### Step 3: Install (only after build verification passes)

```bash
sudo make -C ~/kernel-build modules_install
sudo make -C ~/kernel-build install
```

This installs the kernel as `6.19.9-jmb585fix` alongside your existing kernel.

### Step 4: Reboot and test

```bash
sudo reboot
# Select "6.19.9-jmb585fix" from the GRUB menu
```

After booting the patched kernel:
```bash
# Verify the patch is active — should show "32bit" or "32-bit DMA"
uname -r                                    # Should show 6.19.9-jmb585fix
sudo dmesg | grep -i "ahci.*DMA\|32.*bit"  # Should show 32-bit DMA for c1:00.0

# Run integrity check
sudo btrfs scrub start /mnt/storage
sudo btrfs scrub start /mnt/6tb
```

### Rollback

If anything goes wrong, reboot and select your stock kernel from the GRUB menu.
To remove the custom kernel entirely:

```bash
sudo rm /boot/vmlinuz-6.19.9-jmb585fix
sudo rm /boot/initramfs-6.19.9-jmb585fix.img
sudo rm -rf /lib/modules/6.19.9-jmb585fix
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

## Root Cause Analysis

The N5 Pro data corruption is a three-factor problem:

| Factor | Description | Fix Layer |
|--------|-------------|-----------|
| **JMB585 broken 64-bit DMA** | Controller lies about S64A capability | **This patch** (driver-level) |
| **V1 page table race condition** | `increase_address_space()` race during dynamic growth | Fixed in kernel 6.17+ (software) |
| **Family 1Ah IOMMU errata** | 5-level HATS can issue wider addresses than JMB585 handles | `amd_iommu=pgtbl_v2` (platform-level) |

See `ERRATA-ANALYSIS.md` for the full AMD errata investigation.

## Interaction with pgtbl_v2

During testing, keep `amd_iommu=pgtbl_v2` in place (belt and suspenders). Once
the patch is verified working, `pgtbl_v2` can optionally be removed — the patch
alone should prevent 64-bit DMA addresses from reaching the JMB585. However,
keeping both provides defense in depth:

- **This patch:** Prevents the AHCI driver from enabling 64-bit DMA for the JMB585
- **pgtbl_v2:** Prevents the IOMMU from issuing addresses beyond 47 bits to *any* device
- **Kernel 6.19:** Fixes the V1 page table race that caused corruption during dynamic growth

## Upstream Status

This patch has been accepted into mainline Linux and applied to `libata/linux.git`
(for-7.0-fixes). Upstream commit: https://git.kernel.org/libata/linux/c/105c4256

Cross-platform evidence that supported the submission:
- Minisforum N5 Pro: silent data corruption (BTRFS/ZFS checksum failures)
- Raspberry Pi: kernel panics, requires `pcie-32bit-dma` device tree overlay
- Unraid: "1st FIS failed" errors, drive disappearances
- Proxmox: controller inaccessibility after kernel upgrades
- TrueNAS/FreeBSD: drive detection failures under high I/O
- OpenBSD: NCQ issues, 64-bit DMA cited as problematic
- ASMedia ASM1061 precedent: similar pattern, already fixed in kernel (commit 20730e9b2778)

## References

- AMD Revision Guide #58730 (Family 1Ah Models 10h-1Fh) — IOMMU errata
- AMD Revision Guide #58251 (Family 1Ah Models 00h-0Fh) — IOMMU errata
- AMD IOMMU Specification (document #48882)
- ASMedia ASM1061 43-bit DMA quirk: commit 20730e9b2778 in Linux kernel
- ASMedia ASM106x extension: commit 51af8f255bda in Linux kernel
- Raspberry Pi JMB585 workaround: `pcie-32bit-dma` device tree overlay
- Kernel `increase_address_space()` race fixes: commits 754265bcab78, 140456f994, 1e56310b40fd
- Minisforum N5 Pro Discord community (nas-n5pro channel)
