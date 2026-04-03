# JMB585 Silent Data Corruption — Root Cause Analysis & Kernel Patch

**Video walkthrough:** https://youtu.be/JFkDk3LN4IU

The JMicron JMB585 SATA controller silently corrupts data on Linux systems with wide DMA address spaces. This repository contains the root cause analysis, a kernel patch, and per-OS workaround instructions.

## Am I Affected?

Check if you have a JMB585:
```bash
lspci | grep -i jmicron
```
If you see `JMB58x`, you may be affected — especially on AMD Zen 5 (Strix Point) platforms like the Minisforum N5 Pro.

## Quick Fix (All Distros)

Add `amd_iommu=pgtbl_v2` to your kernel boot parameters:

### Fedora / RHEL / CentOS Stream
```bash
sudo grubby --update-kernel=ALL --args="amd_iommu=pgtbl_v2"
sudo reboot
```

### Ubuntu / Debian / Pop!_OS
```bash
sudo nano /etc/default/grub
# Add amd_iommu=pgtbl_v2 to GRUB_CMDLINE_LINUX_DEFAULT
sudo update-grub
sudo reboot
```

### Arch Linux / Manjaro / EndeavourOS
```bash
# GRUB:
sudo nano /etc/default/grub
# Add amd_iommu=pgtbl_v2 to GRUB_CMDLINE_LINUX_DEFAULT
sudo grub-mkconfig -o /boot/grub/grub.cfg

# systemd-boot:
sudo nano /boot/loader/entries/*.conf
# Add amd_iommu=pgtbl_v2 to the "options" line
```

### Proxmox VE
```bash
nano /etc/default/grub
# Add amd_iommu=pgtbl_v2 to GRUB_CMDLINE_LINUX_DEFAULT
update-grub
reboot
```

### Unraid
```
# Edit USB flash drive: syslinux/syslinux.cfg
# Add amd_iommu=pgtbl_v2 to the "append" line
```

### TrueNAS SCALE
```bash
midclt call system.advanced.update '{"kernel_extra_options":"amd_iommu=pgtbl_v2"}'
# Reboot from TrueNAS UI
```

### Verify After Reboot
```bash
cat /proc/cmdline | grep pgtbl_v2
```

**Note:** This workaround came from the Minisforum Discord community. It works for most users, but some have reported it was not sufficient on its own. The kernel patch below targets the problem at the controller level.

## What's Happening

The JMB585 sets the S64A (Supports 64-bit Addressing) bit in its AHCI Host Capabilities register. The Linux kernel reads this bit, trusts it, and enables 64-bit DMA. But the JMB585's 64-bit DMA implementation is broken — under sustained I/O, data is written to wrong memory addresses with no errors logged.

Three factors stack to cause silent corruption:

1. **The JMB585 lies about 64-bit DMA** — sets S64A but can't reliably handle addresses above 4GB
2. **AMD Zen 5 IOMMU uses 5-level page tables** (57-bit address space) — hands out wider addresses than Zen 4, exposing the controller's lie
3. **IOMMU V1 page table race condition** (pre-kernel 6.17) — concurrent page table growth caused inconsistent mappings

This is the same bug pattern as the ASMedia ASM1062 (kernel commit `edb96a15dc18`), which also falsely advertised 64-bit DMA and was fixed with `AHCI_HFLAG_32BIT_ONLY`.

## The Kernel Patch

The patch adds `AHCI_HFLAG_32BIT_ONLY` for the JMB585 and JMB582, forcing 32-bit DMA at the driver level. See [`patches/`](patches/) for the patch file and build instructions.

After the patch:
```
ahci 0000:c1:00.0: controller can't do 64bit DMA, forcing 32bit
```

This patch has been submitted to the Linux kernel mailing list (`linux-ide@vger.kernel.org`).

## Evidence

The [`evidence/`](evidence/) directory contains before/after captures:

| File | Description |
|------|-------------|
| `dmesg-stock.txt` | Stock kernel — shows `64bit` flag in AHCI capabilities |
| `dmesg-patched.txt` | Patched kernel — shows `forcing 32bit` message |
| `btrfs-stats-*-post-stress.txt` | Zero corruption errors after patch + stress test |
| `scrub-status-*.txt` | BTRFS scrub results — zero errors |
| `smart-sd*.txt` | SMART self-test results — all drives healthy |
| `lspci-*.txt` | PCI device listings |

## Who This Affects

- **Minisforum N5 Pro** — confirmed affected (AMD Zen 5 + JMB585)
- **Any system with a JMB585** on a platform with wide DMA addresses
- **JMB582** — same chip family, same patch applied preventively
- **All Linux filesystems** — but only detectable on BTRFS/ZFS (checksumming). ext4/XFS users may have undetected corruption.

## Credits

- **Minisforum Discord community** — found the `pgtbl_v2` workaround
- **dlitznet** — early IOMMU/DMA analysis that informed this investigation
- **Claude (Anthropic AI)** — kernel source research and patch development
- Investigation framework provided by a friend

Investigation and patch development assisted by Claude (Anthropic AI).

## License

GPL-2.0 — kernel patches must be GPL-2 compatible.
