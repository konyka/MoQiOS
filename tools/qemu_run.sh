#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

KERNEL="zig-out/bin/moqi-kernel.elf"
LIMINE_DIR="limine"
ISO_DIR="iso_root"
ISO_FILE="moqios.iso"

# Check kernel exists
if [ ! -f "$KERNEL" ]; then
    echo "ERROR: Kernel not found at $KERNEL"
    echo "Run 'zig build' first."
    exit 1
fi

# Download Limine if needed
if [ ! -d "$LIMINE_DIR" ]; then
    echo "[limine] Downloading Limine v8.x..."
    git clone https://github.com/limine-bootloader/limine.git \
        --branch=v8.x-binary --depth=1 "$LIMINE_DIR" 2>/dev/null
fi

# Build limine utility if needed
if [ ! -f "$LIMINE_DIR/limine" ]; then
    echo "[limine] Building utility..."
    make -C "$LIMINE_DIR" 2>/dev/null
fi

# Create ISO structure
rm -rf "$ISO_DIR"
mkdir -p "$ISO_DIR/boot/limine"
mkdir -p "$ISO_DIR/EFI/BOOT"

# Copy kernel and config
cp "$KERNEL" "$ISO_DIR/boot/moqi-kernel.elf"
cp limine.conf "$ISO_DIR/boot/limine/"

USER_BIN_DIR="user_bin"
rm -rf "$USER_BIN_DIR"
mkdir -p "$USER_BIN_DIR"

USER_PROGRAMS=(
    init
    hello2 hello3 hello4 hello5 hello6 hello7 hello8 sh
    hello9 hello10 hello11 hello12 hello13 hello14 hello15 hello16
    hello17 hello18 hello19 hello20 hello21 hello22 hello23 hello24
    hello25 hello26 hello27 hello28 hello29 hello30
)
for program in "${USER_PROGRAMS[@]}"; do
    if [ -f "user/${program}.bin" ]; then
        cp "user/${program}.bin" "$USER_BIN_DIR/$program"
    elif [ "$program" = "init" ]; then
        echo "WARNING: user/init.bin not found, building anyway..."
    fi
done
if [ -d "$USER_BIN_DIR" ] && [ "$(ls -A $USER_BIN_DIR)" ]; then
    ./tools/mkramdisk.sh "$USER_BIN_DIR" "$ISO_DIR/boot/ramdisk.bin"
else
    echo "WARNING: No user programs to package"
fi

# Copy Limine binaries
cp "$LIMINE_DIR/limine-bios.sys" "$ISO_DIR/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/limine-bios-cd.bin" "$ISO_DIR/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/limine-uefi-cd.bin" "$ISO_DIR/boot/limine/" 2>/dev/null || true
cp "$LIMINE_DIR/BOOTX64.EFI" "$ISO_DIR/EFI/BOOT/" 2>/dev/null || true

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
"$LIMINE_DIR/limine" bios-install "$ISO_FILE" 2>/dev/null || true

# Launch QEMU
echo "========================================="
echo " MoQiOS — Launching QEMU"
echo " Press Ctrl-A X to exit"

# GDB debug support
QEMU_DEBUG_FLAGS=""
if [ "${MOQI_DEBUG:-}" = "1" ]; then
    QEMU_DEBUG_FLAGS="-s -S"
    echo " GDB stub active on :1234"
    echo " Connect: gdb zig-out/bin/moqi-kernel.elf -ex 'target remote :1234'"
fi

echo "========================================="

# Overridable for diagnostics:
#   MOQI_SERIAL      serial target (default: stdio; e.g. file:/tmp/serial.log)
#   MOQI_SMP         number of CPUs (default: 2)
#   MOQI_DISK        raw disk image path (default: disk.img)
#   MOQI_EXTRA_QEMU  extra QEMU args (e.g. "-d int,cpu_reset -D /tmp/qint.log")
SERIAL_TARGET="${MOQI_SERIAL:-stdio}"
SMP_COUNT="${MOQI_SMP:-2}"
DISK_IMAGE="${MOQI_DISK:-disk.img}"
EXTRA_QEMU="${MOQI_EXTRA_QEMU:-}"

# exec so callers that background this script get the QEMU PID (not a leftover shell).
exec qemu-system-x86_64 \
    -M q35 \
    -m 512M \
    -cdrom "$ISO_FILE" \
    -boot order=d \
    -drive file="$DISK_IMAGE",format=raw,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    -netdev user,id=net0 \
    -device e1000,netdev=net0 \
    -smp "$SMP_COUNT" \
    -serial "$SERIAL_TARGET" \
    -display none \
    -no-reboot \
    -no-shutdown \
    ${QEMU_DEBUG_FLAGS} ${EXTRA_QEMU}
