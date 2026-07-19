//! SK-44 — shared ELF64 header / program-header parsing.
//!
//! The portable core of `loader.zig`: magic/class/endian/machine validation
//! and bounds-checked, alignment-safe program-header reads. Loader keeps the
//! x86-specific page mapping; non-x86 bring-up reuses this module directly
//! (sk44 probe; later the real non-x86 user loaders).

const builtin = @import("builtin");

pub const EI_NIDENT = 16;

/// e_machine expected for binaries loadable on the running kernel.
pub const EM_CURRENT: u16 = switch (builtin.cpu.arch) {
    .x86_64 => 0x3E, // EM_X86_64
    .riscv64 => 0xF3, // EM_RISCV
    .aarch64 => 0xB7, // EM_AARCH64
    else => 0,
};

pub const ET_EXEC: u16 = 2;
pub const ET_DYN: u16 = 3;

pub const PT_LOAD: u32 = 1;
pub const PT_INTERP: u32 = 3;
pub const PT_PHDR: u32 = 6;

pub const PF_X: u32 = 1;
pub const PF_W: u32 = 2;
pub const PF_R: u32 = 4;

pub const Elf64_Ehdr = extern struct {
    e_ident: [EI_NIDENT]u8,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

pub const Elf64_Phdr = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};

/// True when the buffer starts with \x7fELF.
pub fn hasMagic(data: [*]const u8, size: u64) bool {
    if (size < 4) return false;
    return data[0] == 0x7F and data[1] == 'E' and data[2] == 'L' and data[3] == 'F';
}

/// Copy the ELF header out of `data` into an aligned struct and validate it
/// as a loadable executable for the running kernel: magic, ELFCLASS64,
/// little-endian, machine == EM_CURRENT, type ET_EXEC/ET_DYN.
/// Returns null on any failure.
pub fn parseHeader(data: [*]const u8, size: u64) ?Elf64_Ehdr {
    if (size < @sizeOf(Elf64_Ehdr)) return null;
    if (!hasMagic(data, size)) return null;
    var buf: [@sizeOf(Elf64_Ehdr)]u8 align(@alignOf(Elf64_Ehdr)) = undefined;
    @memcpy(buf[0..], data[0..@sizeOf(Elf64_Ehdr)]);
    const ehdr: *const Elf64_Ehdr = @ptrCast(&buf);
    if (ehdr.e_ident[4] != 2) return null; // ELFCLASS64
    if (ehdr.e_ident[5] != 1) return null; // ELFDATA2LSB
    if (ehdr.e_machine != EM_CURRENT) return null;
    if (ehdr.e_type != ET_EXEC and ehdr.e_type != ET_DYN) return null;
    return ehdr.*;
}

/// Bounds-checked, alignment-safe read of program header `i`.
/// Short on-disk entries (phentsize < sizeof(Phdr)) are zero-extended,
/// matching the loader's historical behaviour.
pub fn readPhdr(data: [*]const u8, size: u64, ehdr: *const Elf64_Ehdr, i: usize) ?Elf64_Phdr {
    const phentsize: u64 = ehdr.e_phentsize;
    if (phentsize == 0) return null;
    const start = ehdr.e_phoff + @as(u64, i) * phentsize;
    if (start + phentsize > size) return null;
    var buf: [@sizeOf(Elf64_Phdr)]u8 align(@alignOf(Elf64_Phdr)) = undefined;
    const clen: usize = @intCast(@min(phentsize, @sizeOf(Elf64_Phdr)));
    @memcpy(buf[0..clen], data[start .. start + clen]);
    if (clen < @sizeOf(Elf64_Phdr)) @memset(buf[clen..], 0);
    const phdr: *const Elf64_Phdr = @ptrCast(&buf);
    return phdr.*;
}
