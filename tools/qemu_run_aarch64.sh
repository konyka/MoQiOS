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
DTB_OWNED=0
if [ -z "${MOQI_DTB:-}" ]; then DTB_OWNED=1; fi
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
MEMORY="${MOQI_MEM:-256M}"

if ! [[ "$SMP_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MOQI_SMP must be a positive decimal integer."
    exit 2
fi
if ! [[ "$MEMORY" =~ ^[1-9][0-9]*[KMG]$ ]]; then
    echo "ERROR: MOQI_MEM must be a positive QEMU memory value such as 256M."
    exit 2
fi

# Refresh the automatically owned DTB every run so it cannot become stale when
# MOQI_SMP or MOQI_MEM changes. Explicit MOQI_DTB remains caller-owned.
if [ "$DTB_OWNED" -eq 1 ]; then
    DTB_TMP="${DTB_IMAGE}.tmp.$$"
    trap 'rm -f -- "$DTB_TMP"' EXIT
    qemu-system-aarch64 \
        -machine virt,gic-version=3,dumpdtb="$DTB_TMP" \
        -cpu max \
        -m "$MEMORY" \
        -smp "$SMP_COUNT" \
        -display none
    mv -f -- "$DTB_TMP" "$DTB_IMAGE"
else
    if [ ! -f "$DTB_IMAGE" ]; then
        echo "ERROR: explicit MOQI_DTB does not exist: $DTB_IMAGE"
        exit 2
    fi
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
    -m "$MEMORY" \
    -smp "$SMP_COUNT" \
    -serial "$SERIAL_TARGET" \
    -display none \
    -no-reboot
