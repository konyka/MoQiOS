#!/bin/bash
# Run the MoQiOS aarch64 kernel skeleton under QEMU 'virt'.
#
# Requires qemu-system-aarch64 (Fedora: sudo dnf install qemu-system-aarch64).
# QEMU loads the ELF (-kernel) at 0x40000000 and enters _start in EL1 with
# x0=DTB.
#
# Overridable:
#   MOQI_SERIAL  serial target (default: stdio; e.g. file:/tmp/aa.log)
#   MOQI_SMP     number of CPUs (default: 1)
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KERNEL="zig-out/bin/moqi-kernel-aarch64.elf"

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

echo "========================================="
echo " MoQiOS aarch64 — Launching QEMU (virt)"
echo " Press Ctrl-A X to exit"
echo "========================================="

exec qemu-system-aarch64 \
    -machine virt \
    -cpu max \
    -kernel "$KERNEL" \
    -m 256M \
    -smp "$SMP_COUNT" \
    -serial "$SERIAL_TARGET" \
    -display none \
    -no-reboot
