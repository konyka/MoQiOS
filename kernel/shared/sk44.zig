//! SK-44 — shared ELF64 header/phdr parsing exercised on non-x86.
//!
//! loader.zig's portable core (magic/class/endian/machine/type validation +
//! bounds-checked, alignment-safe phdr reads) moved to `proc/elf.zig` with
//! `EM_CURRENT` selected per arch (EM_X86_64 / EM_RISCV / EM_AARCH64).
//! Probe: synthesize a minimal ELF64 image (Ehdr + one PT_LOAD + one PT_PHDR
//! entry), parse via the shared module, and check rejection of wrong-machine
//! and truncated inputs.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const elf = @import("../proc/elf.zig");

const EHDR = @sizeOf(elf.Elf64_Ehdr); // 64
const PHDR = @sizeOf(elf.Elf64_Phdr); // 56
const IMG_LEN: usize = EHDR + 2 * PHDR;

fn wr16(buf: []u8, off: usize, v: u16) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
}

fn wr32(buf: []u8, off: usize, v: u32) void {
    wr16(buf, off, @truncate(v));
    wr16(buf, off + 2, @truncate(v >> 16));
}

fn wr64(buf: []u8, off: usize, v: u64) void {
    wr32(buf, off, @truncate(v));
    wr32(buf, off + 4, @truncate(v >> 32));
}

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-44] shared elf header parse: OK\n");
        return;
    }

    var img: [IMG_LEN]u8 align(8) = @splat(0);
    // e_ident: magic + ELFCLASS64 + ELFDATA2LSB + EV_CURRENT
    img[0] = 0x7F;
    img[1] = 'E';
    img[2] = 'L';
    img[3] = 'F';
    img[4] = 2; // ELFCLASS64
    img[5] = 1; // ELFDATA2LSB
    img[6] = 1; // EV_CURRENT
    wr16(&img, 16, elf.ET_EXEC); // e_type
    wr16(&img, 18, elf.EM_CURRENT); // e_machine
    wr32(&img, 20, 1); // e_version
    wr64(&img, 24, 0x40_1000); // e_entry
    wr64(&img, 32, EHDR); // e_phoff
    wr16(&img, 54, PHDR); // e_phentsize
    wr16(&img, 56, 2); // e_phnum

    // phdr[0]: PT_LOAD at vaddr 0x40_0000, filesz 0x80, memsz 0x100
    var off: usize = EHDR;
    wr32(&img, off, elf.PT_LOAD);
    wr32(&img, off + 4, elf.PF_R | elf.PF_X);
    wr64(&img, off + 8, 0); // p_offset
    wr64(&img, off + 16, 0x40_0000); // p_vaddr
    wr64(&img, off + 32, 0x80); // p_filesz
    wr64(&img, off + 40, 0x100); // p_memsz
    // phdr[1]: PT_PHDR
    off += PHDR;
    wr32(&img, off, elf.PT_PHDR);
    wr64(&img, off + 16, 0x40_0000 + EHDR);

    if (!elf.hasMagic(&img, IMG_LEN)) {
        arch.serial.writeString("[SK-44] FAILED: hasMagic\n");
        return;
    }
    const ehdr = elf.parseHeader(&img, IMG_LEN) orelse {
        arch.serial.writeString("[SK-44] FAILED: parseHeader\n");
        return;
    };
    if (ehdr.e_entry != 0x40_1000 or ehdr.e_phnum != 2) {
        arch.serial.writeString("[SK-44] FAILED: ehdr fields\n");
        return;
    }

    const ph0 = elf.readPhdr(&img, IMG_LEN, &ehdr, 0) orelse {
        arch.serial.writeString("[SK-44] FAILED: readPhdr(0)\n");
        return;
    };
    if (ph0.p_type != elf.PT_LOAD or ph0.p_vaddr != 0x40_0000 or
        ph0.p_memsz != 0x100 or (ph0.p_flags & elf.PF_X) == 0)
    {
        arch.serial.writeString("[SK-44] FAILED: phdr0 fields\n");
        return;
    }
    const ph1 = elf.readPhdr(&img, IMG_LEN, &ehdr, 1) orelse {
        arch.serial.writeString("[SK-44] FAILED: readPhdr(1)\n");
        return;
    };
    if (ph1.p_type != elf.PT_PHDR) {
        arch.serial.writeString("[SK-44] FAILED: phdr1 type\n");
        return;
    }
    // Out-of-range index must be rejected (bounds check).
    if (elf.readPhdr(&img, IMG_LEN, &ehdr, 2) != null) {
        arch.serial.writeString("[SK-44] FAILED: phdr oob not rejected\n");
        return;
    }

    // Wrong machine must be rejected.
    wr16(&img, 18, elf.EM_CURRENT + 1);
    if (elf.parseHeader(&img, IMG_LEN) != null) {
        arch.serial.writeString("[SK-44] FAILED: wrong machine accepted\n");
        return;
    }
    wr16(&img, 18, elf.EM_CURRENT);
    // Truncated header must be rejected.
    if (elf.parseHeader(&img, EHDR - 1) != null) {
        arch.serial.writeString("[SK-44] FAILED: short header accepted\n");
        return;
    }

    arch.serial.writeString("[SK-44] shared elf header parse: OK\n");
}
