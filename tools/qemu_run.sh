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
if [ -f "user/init.bin" ]; then
    cp "user/init.bin" "$USER_BIN_DIR/init"
else
    echo "WARNING: user/init.bin not found, building anyway..."
fi
if [ -f "user/hello2.bin" ]; then
    cp "user/hello2.bin" "$USER_BIN_DIR/hello2"
fi
if [ -f "user/hello3.bin" ]; then
    cp "user/hello3.bin" "$USER_BIN_DIR/hello3"
fi
if [ -f "user/hello4.bin" ]; then
    cp "user/hello4.bin" "$USER_BIN_DIR/hello4"
fi
if [ -f "user/hello5.bin" ]; then
    cp "user/hello5.bin" "$USER_BIN_DIR/hello5"
fi
if [ -f "user/hello6.bin" ]; then
    cp "user/hello6.bin" "$USER_BIN_DIR/hello6"
fi
if [ -f "user/hello7.bin" ]; then
    cp "user/hello7.bin" "$USER_BIN_DIR/hello7"
fi
if [ -f "user/hello8.bin" ]; then
    cp "user/hello8.bin" "$USER_BIN_DIR/hello8"
fi
if [ -f "user/sh.bin" ]; then
    cp "user/sh.bin" "$USER_BIN_DIR/sh"
fi
if [ -f "user/hello9.bin" ]; then
    cp "user/hello9.bin" "$USER_BIN_DIR/hello9"
fi
if [ -f "user/hello10.bin" ]; then
    cp "user/hello10.bin" "$USER_BIN_DIR/hello10"
fi
if [ -f "user/hello11.bin" ]; then
    cp "user/hello11.bin" "$USER_BIN_DIR/hello11"
fi
if [ -f "user/hello12.bin" ]; then
    cp "user/hello12.bin" "$USER_BIN_DIR/hello12"
fi
if [ -f "user/hello13.bin" ]; then
    cp "user/hello13.bin" "$USER_BIN_DIR/hello13"
fi
if [ -f "user/hello14.bin" ]; then
    cp "user/hello14.bin" "$USER_BIN_DIR/hello14"
fi
if [ -f "user/hello15.bin" ]; then
    cp "user/hello15.bin" "$USER_BIN_DIR/hello15"
fi
if [ -f "user/hello16.bin" ]; then
    cp "user/hello16.bin" "$USER_BIN_DIR/hello16"
fi
if [ -f "user/hello17.bin" ]; then
    cp "user/hello17.bin" "$USER_BIN_DIR/hello17"
fi
if [ -f "user/hello18.bin" ]; then
    cp "user/hello18.bin" "$USER_BIN_DIR/hello18"
fi
if [ -f "user/hello19.bin" ]; then
    cp "user/hello19.bin" "$USER_BIN_DIR/hello19"
fi
if [ -f "user/hello20.bin" ]; then
    cp "user/hello20.bin" "$USER_BIN_DIR/hello20"
fi
if [ -f "user/hello21.bin" ]; then
    cp "user/hello21.bin" "$USER_BIN_DIR/hello21"
fi
if [ -f "user/hello22.bin" ]; then
    cp "user/hello22.bin" "$USER_BIN_DIR/hello22"
fi
if [ -f "user/hello23.bin" ]; then
    cp "user/hello23.bin" "$USER_BIN_DIR/hello23"
fi
if [ -f "user/hello24.bin" ]; then
    cp "user/hello24.bin" "$USER_BIN_DIR/hello24"
fi
if [ -f "user/hello25.bin" ]; then
    cp "user/hello25.bin" "$USER_BIN_DIR/hello25"
fi
if [ -f "user/hello26.bin" ]; then
    cp "user/hello26.bin" "$USER_BIN_DIR/hello26"
fi
if [ -f "user/hello27.bin" ]; then
    cp "user/hello27.bin" "$USER_BIN_DIR/hello27"
fi
if [ -f "user/hello28.bin" ]; then
    cp "user/hello28.bin" "$USER_BIN_DIR/hello28"
fi
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

qemu-system-x86_64 \
    -M q35 \
    -m 512M \
    -cdrom "$ISO_FILE" \
    -boot order=d \
    -drive file=disk.img,format=raw,if=none,id=disk0 \
    -device virtio-blk-pci,drive=disk0 \
    -netdev user,id=net0 \
    -device e1000,netdev=net0 \
    -smp 2 \
    -serial stdio \
    -display none \
    -no-reboot \
    -no-shutdown \
    ${QEMU_DEBUG_FLAGS}
