#!/bin/bash
# build-rpm.sh — Build a custom Fedora kernel with JMB585 32-bit DMA patch
#
# Creates an installable kernel alongside your existing one. The stock kernel
# is never modified — GRUB lets you choose which to boot at startup.
#
# Prerequisites:
#   sudo dnf install rpm-build kernel-devel-$(uname -r) gcc make \
#     bison flex elfutils-libelf-devel openssl-devel perl-generators \
#     python3-devel ncurses-devel bc rsync dwarves
#
# Usage:
#   ./build-rpm.sh [--configure-only | --build | --verify | --clean]
#
#   --configure-only  Extract source, apply patch, configure (no compile)
#   --build           Configure + compile kernel (default)
#   --verify          Check a completed build for correctness
#   --clean           Remove the build directory entirely
#
# After build:
#   sudo make -C ~/kernel-build modules_install
#   sudo make -C ~/kernel-build install
#   # Reboot and select "6.19.9-jmb585fix" from GRUB menu
#
# Rollback:
#   # Select stock kernel from GRUB menu at boot, then:
#   sudo rm /boot/vmlinuz-6.19.9-jmb585fix
#   sudo rm /boot/initramfs-6.19.9-jmb585fix.img
#   sudo rm -rf /lib/modules/6.19.9-jmb585fix
#   sudo grub2-mkconfig -o /boot/grub2/grub.cfg

set -euo pipefail

# --- Configuration -----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/0001-ahci-force-32bit-dma-for-jmb585.patch"
BUILD_DIR="$HOME/kernel-build"
LOCALVERSION="-jmb585fix"
LOG_FILE="$BUILD_DIR/build.log"

# Locate kernel source tarball
SRPM="$HOME/rpmbuild/SOURCES/linux-6.19.9.tar.xz"

# Patch verification strings — all must appear in drivers/ata/ahci.c
PATCH_MARKERS=(
    "board_ahci_jmb585,"
    "[board_ahci_jmb585]"
    "AHCI_HFLAG_32BIT_ONLY"
    "PCI_VDEVICE(JMICRON, 0x0585)"
    "PCI_VDEVICE(JMICRON, 0x0582)"
)

# --- Helpers -----------------------------------------------------------------

# Print a fatal error and exit. All cleanup is handled by the caller or
# by re-running with --clean.
die() { echo "FATAL: $*" >&2; exit 1; }

# Informational log line, prefixed for visibility in long output.
info() { echo "==> $*"; }

# Non-fatal warning. Printed to stderr so it stands out in piped output.
warn() { echo "WARNING: $*" >&2; }

# Verify all required tools and files are present before starting.
# Collects all missing items and reports them together rather than
# failing on the first one — saves the user multiple round trips.
check_prerequisites() {
    local missing=()

    [ -f "$SRPM" ] || missing+=("kernel source ($SRPM) — run: dnf download --source kernel-\$(uname -r | sed 's/.fc.*//')")
    [ -f "$PATCH_FILE" ] || missing+=("patch file ($PATCH_FILE)")
    command -v gcc &>/dev/null || missing+=("gcc — run: sudo dnf install gcc")
    command -v make &>/dev/null || missing+=("make — run: sudo dnf install make")
    [ -f "/boot/config-$(uname -r)" ] || missing+=("kernel config for $(uname -r) — run: sudo dnf install kernel-devel-\$(uname -r)")

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing prerequisites:" >&2
        for m in "${missing[@]}"; do
            echo "  - $m" >&2
        done
        exit 1
    fi
}

# A full kernel build needs ~20GB. Check before starting rather than
# failing mid-compile with an opaque "No space left on device" error.
check_disk_space() {
    local available_gb
    available_gb=$(df --output=avail -BG "$HOME" | tail -1 | tr -d ' G')
    if [ "$available_gb" -lt 20 ]; then
        die "Insufficient disk space: ${available_gb}GB available, need at least 20GB for kernel build"
    fi
    info "Disk space: ${available_gb}GB available"
}

# Extract kernel source tarball to BUILD_DIR. Skips if already extracted.
# On failure, removes the partial directory to avoid a corrupted tree.
extract_source() {
    if [ -f "$BUILD_DIR/Makefile" ]; then
        info "Source already extracted at $BUILD_DIR"
        return
    fi

    info "Extracting kernel source (this takes a minute)..."
    mkdir -p "$BUILD_DIR"
    if ! tar xf "$SRPM" --strip-components=1 -C "$BUILD_DIR"; then
        rm -rf "$BUILD_DIR"
        die "Failed to extract kernel source"
    fi
    info "Source extracted to $BUILD_DIR"
}

# Apply the JMB585 32-bit DMA patch to drivers/ata/ahci.c via sed.
# Three insertion points: enum, port_info array, and PCI ID table.
# Backs up the original file to ahci.c.orig for diffing.
# Idempotent — skips if patch markers are already present.
apply_patch() {
    local ahci="$BUILD_DIR/drivers/ata/ahci.c"

    if grep -q "board_ahci_jmb585" "$ahci" 2>/dev/null; then
        info "Patch already applied"
        return
    fi

    info "Applying JMB585 32-bit DMA patch..."

    # Keep a backup for diffing
    cp "$ahci" "$ahci.orig"

    # Edit 1: Add enum entry after board_ahci_ign_iferr
    sed -i '/board_ahci_ign_iferr,/a\\tboard_ahci_jmb585,' "$ahci"

    # Edit 2: Add port info entry after the board_ahci_ign_iferr block
    sed -i '/\[board_ahci_ign_iferr\] = {/,/^[[:space:]]*},/{
        /^[[:space:]]*},/a\\t/* JMicron JMB582\/585: 64-bit DMA is broken, force 32-bit */\n\t[board_ahci_jmb585] = {\n\t\tAHCI_HFLAGS\t(AHCI_HFLAG_IGN_IRQ_IF_ERR |\n\t\t\t\t AHCI_HFLAG_32BIT_ONLY),\n\t\t.flags\t\t= AHCI_FLAG_COMMON,\n\t\t.pio_mask\t= ATA_PIO4,\n\t\t.udma_mask\t= ATA_UDMA6,\n\t\t.port_ops\t= \&ahci_ops,\n\t},
    }' "$ahci"

    # Edit 3: Add PCI device ID entries before the generic JMicron class match
    sed -i '/JMicron 360\/1\/3\/5\/6, match class to avoid IDE function/i\\t/* JMicron JMB582\/585: force 32-bit DMA (broken 64-bit implementation) */\n\t{ PCI_VDEVICE(JMICRON, 0x0582), board_ahci_jmb585 },\n\t{ PCI_VDEVICE(JMICRON, 0x0585), board_ahci_jmb585 },' "$ahci"

    info "Patch applied"
}

# Verify the patch was applied correctly by checking for all expected
# markers in ahci.c. Also confirms the reference count — we expect at
# least 4 occurrences of board_ahci_jmb585 (enum, port_info, 2x PCI ID).
verify_patch() {
    local ahci="$BUILD_DIR/drivers/ata/ahci.c"
    local failed=0

    info "Verifying patch markers in $ahci..."
    for marker in "${PATCH_MARKERS[@]}"; do
        if ! grep -qF "$marker" "$ahci"; then
            warn "Missing patch marker: $marker"
            failed=1
        fi
    done

    if [ "$failed" -eq 1 ]; then
        die "Patch verification failed — one or more markers missing"
    fi

    # Verify structural correctness: enum, port_info, and pci_tbl entries
    # must all reference board_ahci_jmb585
    local count
    count=$(grep -c "board_ahci_jmb585" "$ahci")
    if [ "$count" -lt 4 ]; then
        die "Expected at least 4 references to board_ahci_jmb585, found $count"
    fi

    info "Patch verified: $count references to board_ahci_jmb585"
}

# Copy the running kernel's config as a base, set LOCALVERSION to tag
# this build, and disable debug info (cuts build time ~50% and reduces
# output size from ~10GB to ~3GB). Uses 'make olddefconfig' to accept
# defaults for any config options that differ between kernel versions.
configure_kernel() {
    cd "$BUILD_DIR"

    info "Configuring kernel..."
    cp "/boot/config-$(uname -r)" .config

    # Tag this build so it's identifiable
    scripts/config --set-str LOCALVERSION "$LOCALVERSION"

    # Disable debug info — cuts build time roughly in half and reduces disk usage
    scripts/config --disable DEBUG_INFO
    scripts/config --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
    scripts/config --disable DEBUG_INFO_DWARF4
    scripts/config --disable DEBUG_INFO_DWARF5
    scripts/config --enable DEBUG_INFO_NONE

    # Accept defaults for any new/changed config options
    if ! make olddefconfig; then
        die "Kernel config generation failed"
    fi

    local release
    release=$(make -s kernelrelease)
    info "Kernel configured: $release"
}

# Compile bzImage and all kernel modules. Uses all available CPU cores.
# Output is tee'd to a log file for post-mortem debugging if it fails.
# This step takes 1-2+ hours depending on hardware.
build_kernel() {
    cd "$BUILD_DIR"

    local jobs
    jobs=$(nproc)
    local release
    release=$(make -s kernelrelease)

    info "Building kernel $release with $jobs parallel jobs..."
    info "Build log: $LOG_FILE"
    info "This will take 1-2+ hours. You can monitor with: tail -f $LOG_FILE"
    echo ""

    if ! make -j"$jobs" bzImage modules 2>&1 | tee "$LOG_FILE"; then
        die "Kernel build failed. Check $LOG_FILE for details."
    fi

    info "Build complete: $release"
}

# Post-build verification. Checks:
#   1. bzImage exists and has reasonable size
#   2. ahci.o contains the board_ahci_jmb585 symbol
#   3. PCI vendor/device IDs (197b:0585) are present in the binary
#   4. Kernel release string matches expected version
# Returns non-zero if any check fails — do not install without passing.
verify_build() {
    cd "$BUILD_DIR"

    local release
    release=$(make -s kernelrelease)
    local failed=0

    info "Verifying build: $release"

    # Check bzImage exists
    if [ -f "arch/x86/boot/bzImage" ]; then
        info "  bzImage: OK ($(du -h arch/x86/boot/bzImage | cut -f1))"
    else
        warn "  bzImage: MISSING"
        failed=1
    fi

    # Check ahci.o was built and contains our PCI IDs.
    # Note: board_ahci_jmb585 is a C enum constant — it gets compiled to an
    # integer and does not appear in the symbol table. We verify by checking
    # for the JMicron PCI vendor+device IDs in the binary data instead.
    local ahci_obj="drivers/ata/ahci.o"
    if [ -f "$ahci_obj" ]; then
        info "  ahci.o: OK ($(du -h "$ahci_obj" | cut -f1))"

        # Check for JMB585 PCI device ID (0x0585) near JMicron vendor ID (0x197b)
        # In the PCI ID table, vendor and device are stored as little-endian 32-bit
        # fields: vendor 0x197b → "7b19", device 0x0585 → "8505"
        if python3 -c "
data = open('$ahci_obj', 'rb').read()
import struct
vendor = struct.pack('<H', 0x197b)
dev585 = struct.pack('<H', 0x0585)
dev582 = struct.pack('<H', 0x0582)
found_585 = dev585 in data
found_582 = dev582 in data
found_vendor = data.count(vendor)
# Stock kernel has 4 vendor refs (class match + 2362 + 236f + quirk)
# Our patch adds 2 more (0582 + 0585) = 6 total
print(f'vendor 0x197b: {found_vendor} instances')
print(f'JMB585 0x0585: {\"FOUND\" if found_585 else \"MISSING\"}')
print(f'JMB582 0x0582: {\"FOUND\" if found_582 else \"MISSING\"}')
exit(0 if (found_585 and found_582 and found_vendor >= 6) else 1)
" 2>/dev/null; then
            info "  ahci.o PCI IDs: JMB582 + JMB585 entries verified"
        else
            warn "  ahci.o PCI IDs: verification failed"
            failed=1
        fi
    else
        warn "  ahci.o: MISSING"
        failed=1
    fi

    # Check kernel release matches expected
    if [ "$release" = "6.19.9${LOCALVERSION}" ]; then
        info "  Kernel release: $release OK"
    else
        warn "  Kernel release: expected 6.19.9${LOCALVERSION}, got $release"
        failed=1
    fi

    # Summary
    echo ""
    if [ "$failed" -eq 0 ]; then
        info "=== BUILD VERIFICATION PASSED ==="
        echo ""
        echo "Next steps:"
        echo "  1. Back up anything critical"
        echo "  2. sudo make -C $BUILD_DIR modules_install"
        echo "  3. sudo make -C $BUILD_DIR install"
        echo "  4. Reboot and select '$release' from GRUB"
        echo "  5. Verify: dmesg | grep -i '32-bit DMA'"
        echo "  6. If issues: reboot into stock kernel ($(uname -r))"
    else
        warn "=== BUILD VERIFICATION FOUND ISSUES ==="
        echo "Review warnings above before installing."
        return 1
    fi
}

# Remove the entire build directory. Safe — this only deletes the
# working copy in ~/kernel-build, not the source RPM or any installed
# kernels. Use after a successful install to reclaim ~20GB.
do_clean() {
    if [ -d "$BUILD_DIR" ]; then
        local size
        size=$(du -sh "$BUILD_DIR" 2>/dev/null | cut -f1)
        info "Removing $BUILD_DIR ($size)..."
        rm -rf "$BUILD_DIR"
        info "Clean complete"
    else
        info "Nothing to clean — $BUILD_DIR does not exist"
    fi
}

# --- Main --------------------------------------------------------------------

# Entry point. Dispatches to the appropriate workflow based on the
# command-line flag. Default is --build (full configure + compile).
main() {
    local mode="${1:---build}"

    echo "=== JMB585 32-bit DMA Kernel Build ==="
    echo "Patch:     $PATCH_FILE"
    echo "Build dir: $BUILD_DIR"
    echo "Target:    6.19.9${LOCALVERSION}"
    echo ""

    case "$mode" in
        --configure-only)
            check_prerequisites
            check_disk_space
            extract_source
            apply_patch
            verify_patch
            configure_kernel
            echo ""
            info "Configuration complete. Run '$0 --build' to compile."
            ;;
        --build)
            check_prerequisites
            check_disk_space
            extract_source
            apply_patch
            verify_patch
            configure_kernel
            build_kernel
            verify_build
            ;;
        --verify)
            if [ ! -d "$BUILD_DIR" ]; then
                die "No build directory found at $BUILD_DIR"
            fi
            verify_patch
            verify_build
            ;;
        --clean)
            do_clean
            ;;
        --help|-h)
            head -30 "$0" | grep '^#' | sed 's/^# \?//'
            ;;
        *)
            die "Unknown option: $mode (use --help for usage)"
            ;;
    esac
}

main "$@"
