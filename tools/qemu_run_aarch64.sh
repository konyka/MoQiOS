#!/bin/bash
# Run the MoQiOS aarch64 kernel skeleton under QEMU 'virt'.
#
# Requires qemu-system-aarch64 (Fedora: sudo dnf install qemu-system-aarch64).
# QEMU loads the ELF (-kernel) at 0x40000000 and enters _start in EL1.
# Non-Linux ELF images do not receive a DTB pointer in x0, so we dump the
# virt machine DTB and load it at a fixed address (0x4a000000) for the kernel.
#
# Overridable:
#   MOQI_SERIAL  serial target (default: stdio; e.g. file:/tmp/aa.log)
#   MOQI_SMP     number of CPUs (default: 1)
#   MOQI_DTB     path to DTB (default: /tmp/moqios-aarch64-virt.dtb)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KERNEL="zig-out/bin/moqi-kernel-aarch64.elf"
DTB_IMAGE="${MOQI_DTB:-/tmp/moqios-aarch64-virt.dtb}"
DTB_ADDR=0x4a000000

if [ ! -f "$KERNEL" ]; then
    echo "ERROR: $KERNEL not found. Run: zig build -Darch=aarch64"
    exit 1
fi

if ! command -v qemu-system-aarch64 &>/dev/null; then
    echo "ERROR: qemu-system-aarch64 not found."
    echo "  Fedora:        sudo dnf install qemu-system-aarch64"
    echo "  Debian/Ubuntu: sudo apt install qemu-system-arm"
    exit 1
fi

SERIAL_TARGET="${MOQI_SERIAL:-stdio}"
SMP_COUNT="${MOQI_SMP:-1}"

# Refresh DTB when missing (matches -m/-smp/gic used below).
if [ ! -f "$DTB_IMAGE" ]; then
    qemu-system-aarch64 \
        -machine virt,gic-version=3,dumpdtb="$DTB_IMAGE" \
        -cpu max \
        -m 256M \
        -smp "$SMP_COUNT" \
        -display none
fi

echo "========================================="
echo " MoQiOS aarch64 — Launching QEMU (virt)"
echo " Press Ctrl-A X to exit"
echo "========================================="

exec qemu-system-aarch64 \
    -machine virt,gic-version=3 \
    -cpu max \
    -kernel "$KERNEL" \
    -device loader,file="$DTB_IMAGE",addr="$DTB_ADDR",force-raw=on \
    -m 256M \
    -smp "$SMP_COUNT" \
    -serial "$SERIAL_TARGET" \
    -display none \
    -no-reboot
