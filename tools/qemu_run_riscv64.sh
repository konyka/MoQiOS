#!/bin/bash
# Run the MoQiOS riscv64 kernel skeleton under QEMU 'virt' via OpenSBI.
#
# Requires qemu-system-riscv64 (Fedora: sudo dnf install qemu-system-riscv).
# OpenSBI is QEMU's default riscv64 firmware (-bios default); it loads our ELF
# (-kernel) and enters _start in S-mode with a0=hartid, a1=DTB.
#
# Overridable:
#   MOQI_SERIAL  serial target (default: stdio; e.g. file:/tmp/rv.log)
#   MOQI_SMP     number of harts (default: 1)
#   MOQI_DISK    raw disk image for virtio-blk (default: auto-created temp)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KERNEL="zig-out/bin/moqi-kernel-riscv64.elf"

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: $KERNEL not found. Run: zig build -Darch=riscv64"
    exit 1
fi

if ! command -v qemu-system-riscv64 &>/dev/null; then
    echo "ERROR: qemu-system-riscv64 not found."
    echo "  Fedora:        sudo dnf install qemu-system-riscv"
    echo "  Debian/Ubuntu: sudo apt install qemu-system-misc"
    exit 1
fi

SERIAL_TARGET="${MOQI_SERIAL:-stdio}"
SMP_COUNT="${MOQI_SMP:-1}"
DISK_IMAGE="${MOQI_DISK:-/tmp/moqios-riscv64-disk.img}"

# M7: virtio-blk test disk — sector 0 starts with a known magic string.
if [ ! -f "$DISK_IMAGE" ]; then
    dd if=/dev/zero of="$DISK_IMAGE" bs=512 count=64 status=none
    printf 'MOQI_RV64_DISK' | dd of="$DISK_IMAGE" conv=notrunc status=none
fi

echo "========================================="
echo " MoQiOS riscv64 — Launching QEMU (virt + OpenSBI)"
echo " Press Ctrl-A X to exit"
echo "========================================="

exec qemu-system-riscv64 \
    -machine virt \
    -bios default \
    -kernel "$KERNEL" \
    -m 256M \
    -smp "$SMP_COUNT" \
    -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
    -device virtio-blk-device,drive=disk0 \
    -netdev user,id=net0 \
    -device virtio-net-device,netdev=net0 \
    -serial "$SERIAL_TARGET" \
    -display none \
    -no-reboot
