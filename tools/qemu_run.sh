#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KERNEL="zig-out/bin/moqi-kernel.elf"
LIMINE_DIR="limine"
ISO_DIR="${MOQI_ISO_DIR:-iso_root}"
ISO_FILE="${MOQI_ISO_FILE:-moqios.iso}"
USER_BIN_DIR="${MOQI_USER_BIN_DIR:-user_bin}"
USER_SRC_DIR="${MOQI_USER_SRC_DIR:-zig-out/user}"

# Keep the Limine bootstrap independently testable from the QEMU launch path.
source "$SCRIPT_DIR/limine_bootstrap.sh"

DISK_IMAGE="${MOQI_DISK:-disk.img}"
if [ -z "${MOQI_DISK:-}" ]; then
    "$SCRIPT_DIR/disk_fixture.sh" disk.img.manifest "$DISK_IMAGE"
elif [ ! -f "$DISK_IMAGE" ]; then
    echo "ERROR: disk image missing at $DISK_IMAGE (required by virtio-blk)."
    exit 1
fi

# Check kernel exists
if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    echo "Run 'zig build' first."
    exit 1
fi

limine_prepare "$LIMINE_DIR"

# Create ISO structure
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/limine"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy kernel and config
cp "$KERNEL" "$ISO_DIR/boot/moqi-kernel.elf"
cp limine.conf "$ISO_DIR/boot/limine/"

rm -rf "$USER_BIN_DIR"
mkdir -p "$USER_BIN_DIR"

USER_PROGRAMS=(
    init
    hello2 hello3 hello4 hello5 hello6 hello7 hello8 sh
    hello9 hello10 hello11 hello12 hello13 hello14 hello15 hello16
    hello17 hello18 hello19 hello20 hello21 hello22 hello23 hello24
    hello25 hello26 hello27 hello28 hello29 hello30 hello31 hello32 hello33 hello34 hello35 hello36 hello37 hello38 hello39 hello40 hello41 hello42 hello43 hello44 hello45 hello46 hello47 hello48 hello49 hello50 hello51 hello52 hello53 hello54 hello56 hello57 hello58 hello59 hello60 hello61 hello62 hello63 hello64 syslogd devmgr
)
for program in "${USER_PROGRAMS[@]}"; do
    src="$USER_SRC_DIR/${program}.bin"
    if [ ! -f "$src" ]; then
        echo "ERROR: user program '$program' missing: $src not found."
        echo "Run 'zig build' first (user programs are installed to zig-out/user/)."
        exit 1
    fi
    cp "$src" "$USER_BIN_DIR/$program"
done
if [ -d "$USER_BIN_DIR" ] && [ "$(ls -A "$USER_BIN_DIR")" ]; then
    ./tools/mkramdisk.sh "$USER_BIN_DIR" "$ISO_DIR/boot/ramdisk.bin"
else
    echo "WARNING: No user programs to package"
fi

# Copy Limine binaries verified by limine_prepare.
cp -- "$LIMINE_DIR/limine-bios.sys" "$ISO_DIR/boot/limine/"
cp -- "$LIMINE_DIR/limine-bios-cd.bin" "$ISO_DIR/boot/limine/"
cp -- "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_DIR/boot/limine/"
cp -- "$LIMINE_DIR/BOOTX64.EFI" "$ISO_DIR/EFI/BOOT/"

# Create ISO
if ! command -v xorriso &>/dev/null; then
    echo "ERROR: xorriso not found. Install with:"
    echo "  dnf install xorriso    # Fedora"
    echo "  apt install xorriso     # Debian/Ubuntu"
    exit 1
fi

xorriso -as mkisofs \
    -b boot/limine/limine-bios-cd.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    --efi-boot boot/limine/limine-uefi-cd.bin \
    -efi-boot-part --efi-boot-image --protective-msdos-label \
    "$ISO_DIR" -o "$ISO_FILE" 2>/dev/null

# Install Limine BIOS stages
limine_bios_install "$LIMINE_DIR" "$ISO_FILE"

# Launch QEMU
echo "========================================="
echo " MoQiOS — Launching QEMU"
echo " Press Ctrl-A X to exit"

# GDB debug support
QEMU_DEBUG_FLAGS=()
if [ "${MOQI_DEBUG:-}" = "1" ]; then
    QEMU_DEBUG_FLAGS=(-s -S)
    echo " GDB stub active on :1234"
    echo " Connect: gdb zig-out/bin/moqi-kernel.elf -ex 'target remote :1234'"
fi

echo "========================================="

# Overridable for diagnostics:
#   MOQI_SERIAL      serial target (default: stdio; e.g. file:/tmp/serial.log)
#   MOQI_SMP         number of CPUs (default: 2)
#   MOQI_DISK        raw disk image path (default: disk.img)
#   MOQI_NVME        attach an NVMe controller when != 0 (default: 1)
#   MOQI_NVME_IMG    NVMe scratch image path (default: nvme.img); created and
#                    pattern-stamped automatically when NVMe is enabled
#   MOQI_AHCI        attach an AHCI/SATA controller + scratch disk when != 0
#                    (default: 1)
#   MOQI_AHCI_IMG    SATA scratch image path (default: ahci.img); created and
#                    pattern-stamped automatically when AHCI is enabled
#   MOQI_ISO_DIR     ISO staging directory (default: iso_root)
#   MOQI_ISO_FILE    generated ISO path (default: moqios.iso)
#   MOQI_USER_BIN_DIR ramdisk input directory (default: user_bin)
#   MOQI_USER_SRC_DIR built user-program directory (default: zig-out/user)
#   MOQI_EXTRA_QEMU  extra QEMU args (e.g. "-d int,cpu_reset -D /tmp/qint.log")
SERIAL_TARGET="${MOQI_SERIAL:-stdio}"
SMP_COUNT="${MOQI_SMP:-2}"
NVME_IMAGE="${MOQI_NVME_IMG:-nvme.img}"
AHCI_IMAGE="${MOQI_AHCI_IMG:-ahci.img}"
EXTRA_QEMU_ARGS=()
if [ -n "${MOQI_EXTRA_QEMU:-}" ]; then
    # Split an explicitly documented space-delimited option string once; array
    # expansion preserves each resulting argument and disables glob expansion.
    read -r -a EXTRA_QEMU_ARGS <<< "$MOQI_EXTRA_QEMU"
fi

if ! [[ "$SMP_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MOQI_SMP must be a positive decimal integer (got '$SMP_COUNT')."
    exit 2
fi

# Optional NVMe controller (scratch image; the virtio-blk disk above stays
# the boot/root disk). The kernel stamps a boot-time interrupt-driven read
# against this known first-sector pattern.
NVME_ARGS=()
if [ "${MOQI_NVME:-1}" != "0" ]; then
    if [ ! -f "$NVME_IMAGE" ]; then
        truncate -s 8M "$NVME_IMAGE"
    fi
    printf 'MoQiNVMe' | dd of="$NVME_IMAGE" bs=1 conv=notrunc status=none
    NVME_ARGS=(-drive file="$NVME_IMAGE",format=raw,if=none,id=nvm0
        -device nvme,serial=moqi,drive=nvm0)
fi

# Optional AHCI/SATA controller with a scratch disk (the virtio-blk disk above
# stays the boot/root disk). The kernel runs a boot-time I/O self-test against
# this known first-sector pattern; the write path is only exercised when the
# pattern matches, so a real disk is never written.
AHCI_ARGS=()
if [ "${MOQI_AHCI:-1}" != "0" ]; then
    if [ ! -f "$AHCI_IMAGE" ]; then
        truncate -s 8M "$AHCI_IMAGE"
    fi
    printf 'MoQiAHCI' | dd of="$AHCI_IMAGE" bs=1 conv=notrunc status=none
    AHCI_ARGS=(-device ich9-ahci,id=ahci0
        -drive file="$AHCI_IMAGE",format=raw,if=none,id=sata0
        -device ide-hd,drive=sata0,bus=ahci0.0)
fi

# exec so callers that background this script get the QEMU PID (not a leftover shell).
exec qemu-system-x86_64 \
    -M q35 \
    -m 512M \
    -cdrom "$ISO_FILE" \
    -boot order=d \
    -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    "${NVME_ARGS[@]}" \
    "${AHCI_ARGS[@]}" \
    -netdev user,id=net0 \
    -device e1000,netdev=net0 \
    -smp "$SMP_COUNT" \
    -serial "$SERIAL_TARGET" \
    -display none \
    -no-reboot \
    -no-shutdown \
    "${QEMU_DEBUG_FLAGS[@]}" "${EXTRA_QEMU_ARGS[@]}"
