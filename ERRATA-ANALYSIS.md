# AMD Family 1Ah IOMMU Errata Analysis — Minisforum N5 Pro

**Date:** 26-03-2026
**Processor:** AMD Ryzen AI 9 HX PRO 370 (Strix Point, Family 1Ah)
**Kernel:** 6.19.9-200.fc43.x86_64
**IOMMU EFR:** 0x246577efa2254afa
**IOMMU EFR2:** 0x10

## IOMMU Feature Status

| Feature | Status | Bit |
|---------|--------|-----|
| SATS (Secure Address Translation Service) | **NOT SUPPORTED** | EFR[62] = 0 |
| Guest Translation (GT) | Enabled | EFR[5] = 1 |
| GIOV (Guest I/O Virtualization) | Enabled | EFR2[4] = 1 |
| HATS (Host Address Translation Size) | 5-level (57-bit) | EFR[12:11] = 1 |
| GATS (Guest Address Translation Size) | 6-level | EFR[14:13] = 2 |
| NX (No Execute) | Enabled | EFR[4] = 1 |
| HADUpdate (HW Access/Dirty) | Enabled | EFR[44] = 1 |
| Invalidate All | Enabled | EFR[7] = 1 |
| SNP AVIC | Enabled | EFR[54] = 1 |
| SNP | **NOT SUPPORTED** | EFR2[0] = 0 |
| Guest vAPIC (GA) | Not supported | EFR[8] = 0 |
| PPR (Peripheral Page Request) | Not supported | EFR[2] = 0 |
| Performance Counters | Not supported | EFR[10] = 0 |
| PASIDMax | 2-bit (max 4 PASIDs) | EFR[28:24] = 2 |
| SMI Filter | Supported, 1 pair | EFR[20:18] = 1 |
| Dual Event Log | Supported | EFR[59:58] = 1 |
| Dual PPR Log | Not supported | EFR[57:56] = 0 |

## Important Clarification

Documents #58730 and #58251 officially cover EPYC 9005 (Turin, server SP5 package),
NOT the Strix Point mobile APU in this N5 Pro. AMD has not published a public
revision guide specifically for Strix Point mobile. However, the errata are shared
across Zen 5 silicon (same IP blocks for IOMMU, PCIe root complex, memory controller),
so they remain relevant to this investigation.

## Applicable AMD Errata (Documents #58730 / #58251)

### Erratum 1489 — IOMMU Unpinned Mode + SATS
- **Status: DOES NOT APPLY**
- SATS is not supported on this IOMMU (EFR bit 62 = 0)
- The erratum requires SATS to be enabled to trigger "unpredictable device behavior"

### Erratum 1155 — DMA Target Abort in GPA Range FD_0000_0000-FD_FFFF_FFFF
- **Status: LOW RISK (bare metal)**
- Only applies when virtualization is enabled AND IOMMU is in passthrough mode
- System is running in Translated mode, not passthrough
- Would apply if VMs with PCI passthrough are used in the future

### Erratum 1580 — Silent PCIe ATS Poisoned Data Hang
- **Status: POTENTIALLY RELEVANT**
- GT and GIOV are enabled on this IOMMU
- If PCIe ATS transactions transmit corrupted data, system hangs with no error logged
- No workaround available; no fix planned

### Erratum 1305 — AHCI Controller Ignores COMINIT During HP6:HR_AwaitAlign
- **Status: MINOR**
- Could cause SATA link to negotiate at lower speed
- May explain why some users needed `libata.force=1.5Gbps` as a workaround
- All drives currently at 6.0 Gbps, so not currently affecting this system

### Erratum 1545 — Erroneous PCIe DPC Triggering
- **Status: MONITOR**
- Could cause unexpected PCIe link drops
- Would manifest as sudden SATA controller disappearance

## Kernel-Side Bugs (Fixed in 6.19)

### V1 Page Table Race Condition (increase_address_space)
- **Three rounds of fixes:**
  1. 2019 (754265bcab78) — No locking during page table growth
  2. 2021 (140456f994) — Sleeping in atomic context under spinlock
  3. 2025 (1e56310b40fd, v6.17-rc6) — `fetch_pte()` reads root/mode without synchronization (seqcount fix)
- **Status: FIXED in kernel 6.19** — entire v1 page table code rewritten with generic framework
- **This was likely the primary software cause of the N5 Pro corruption on earlier kernels**

### 6.19 Strix Point Boot Regression
- Commit 789a5913b29c introduced shared IOMMU page tables
- `iommu_iova_to_phys()` returns 0 for both "unmapped" and "mapped to 0x0"
- Strix BIOSes with legitimate 0x0 identity mapping triggered IO_PAGE_FAULT
- **Status: FIXED in kernel 6.19.7** (our kernel is 6.19.9)

## Root Cause Assessment

The N5 Pro silent data corruption is a **three-factor problem**:

| Factor | Description | Current Status |
|--------|-------------|----------------|
| **V1 page table race** | `increase_address_space()` race during 3→4 level growth; readers see inconsistent root/mode | **FIXED** — kernel 6.19.9 has full rewrite |
| **JMB585 broken 64-bit DMA** | Controller falsely advertises S64A; DMA above 4GB truncated or misrouted | **MITIGATED** by pgtbl_v2 (47-bit max); **PATCH PENDING** for AHCI_HFLAG_32BIT_ONLY |
| **Family 1Ah IOMMU** | 5-level HATS (57-bit) can hand out wider addresses than JMB585 handles | **MITIGATED** by pgtbl_v2 (constrains to 4-level/47-bit) |

### Why pgtbl_v2 Works (Correctly Understood)

`pgtbl_v2` fixes the corruption **not** primarily because of address space reduction, but because:
1. V2 page tables are **fixed-depth** — set at init, never grow dynamically
2. There is **no `increase_address_space()` equivalent** in v2
3. This makes v2 **immune to the entire class of race conditions** that plagued v1
4. As a bonus, 4-level (47-bit) keeps DMA addresses within the JMB585's actual capability

### Defense in Depth (Current Configuration)

1. **Kernel 6.19.9** — V1 page table rewrite (race condition fixed at architectural level)
2. **`amd_iommu=pgtbl_v2`** — Fixed-depth page tables, no dynamic growth, 47-bit max
3. **`pcie_aspm=off`** — Eliminates PCIe power state transition issues
4. **BTRFS checksumming** — Detects any corruption that occurs despite above mitigations
5. **Pending: JMB585 32-bit DMA patch** — Prevents 64-bit DMA at the driver level

## Open Questions

1. Given that kernel 6.19.9 fixes the V1 race condition, is `pgtbl_v2` still necessary?
   - Probably yes: it still constrains the JMB585 to safe addresses
   - The JMB585 32-bit DMA patch would be the proper fix at that layer
   - With both the kernel fix AND the JMB585 patch, pgtbl_v2 becomes optional belt-and-suspenders

2. Erratum 1305 (AHCI COMINIT during HP6) — could this interact with SATA link issues
   under sustained I/O? Worth monitoring.

3. The PASIDMax = 2 (only 4 PASIDs) is unusually small for a Zen 5 part. This may
   indicate limitations in the client-class IOMMU implementation vs. server (EPYC).

## References

- AMD Revision Guide #58730 (Family 1Ah Models 10h-1Fh, Turin/Zen5c server)
- AMD Revision Guide #58251 (Family 1Ah Models 00h-0Fh, Zen5 desktop/mobile)
- AMD IOMMU Specification (document #48882)
- Kernel commits: 754265bcab78, 140456f994, 1e56310b40fd, 789a5913b29c
- Kernel v6.19 generic page table framework rewrite (Jason Gunthorpe, Alejandro Jimenez)
