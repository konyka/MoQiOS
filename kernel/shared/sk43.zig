//! SK-43 — shared ramdisk parser exercised on non-x86.
//!
//! `fs/ramdisk.zig` is already arch-clean (serial via the arch facade, no
//! Limine types) but only x86 ever ran it. main.zig's module parse now goes
//! through `subsystem_boot.initRamdisk`; the archive *source* stays
//! arch-specific (Limine module on x86, synthesized blob here). Probe:
//! build a minimal MRD archive (header + 2 entries + data), init via the
//! shared fragment, then `findFile` / `getFileCount` / `getFileName` and a
//! missing-name lookup.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");
const ramdisk = @import("../fs/ramdisk.zig");

const HEADER_SIZE: usize = 32;
const ENTRY_SIZE: usize = 80;
const FILE_A = "init";
const FILE_B = "hello.txt";
const DATA_A = "MoQi-init!";
const DATA_B = "sk43";

// header + 2 entries + data for both files.
const BLOB_SIZE: usize = HEADER_SIZE + 2 * ENTRY_SIZE + DATA_A.len + DATA_B.len;

fn writeU32(buf: []u8, off: usize, v: u32) void {
    buf[off] = @truncate(v);
    buf[off + 1] = @truncate(v >> 8);
    buf[off + 2] = @truncate(v >> 16);
    buf[off + 3] = @truncate(v >> 24);
}

fn writeU64(buf: []u8, off: usize, v: u64) void {
    writeU32(buf, off, @truncate(v));
    writeU32(buf, off + 4, @truncate(v >> 32));
}

fn writeEntry(buf: []u8, idx: usize, name: []const u8, offset: u64, size: u64) void {
    const base = HEADER_SIZE + idx * ENTRY_SIZE;
    @memcpy(buf[base .. base + name.len], name);
    writeU64(buf, base + 64, offset);
    writeU64(buf, base + 72, size);
}

// Static: `ramdisk.init` keeps `state.base` pointing at the blob after the
// probe returns, so it must not live on the probe's stack frame.
var blob: [BLOB_SIZE]u8 align(8) = @splat(0);

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-43] shared ramdisk parse: OK\n");
        return;
    }

    blob[0] = 'M';
    blob[1] = 'R';
    blob[2] = 'D';
    writeU32(blob[0..], 4, 2); // file_count
    writeEntry(blob[0..], 0, FILE_A, 0, DATA_A.len);
    writeEntry(blob[0..], 1, FILE_B, DATA_A.len, DATA_B.len);
    const data_off = HEADER_SIZE + 2 * ENTRY_SIZE;
    @memcpy(blob[data_off .. data_off + DATA_A.len], DATA_A);
    @memcpy(blob[data_off + DATA_A.len ..], DATA_B);

    // Same boot fragment main.zig calls for the Limine module (SK-43).
    if (!subsystem_boot.initRamdisk(@ptrCast(&blob), BLOB_SIZE)) {
        arch.serial.writeString("[SK-43] FAILED: init\n");
        return;
    }
    if (ramdisk.getFileCount() != 2) {
        arch.serial.writeString("[SK-43] FAILED: file count\n");
        return;
    }

    const f = ramdisk.findFile(FILE_A) orelse {
        arch.serial.writeString("[SK-43] FAILED: findFile(init)\n");
        return;
    };
    if (f.size != DATA_A.len) {
        arch.serial.writeString("[SK-43] FAILED: init size\n");
        return;
    }
    for (DATA_A, 0..) |c, i| {
        if (f.data[i] != c) {
            arch.serial.writeString("[SK-43] FAILED: init data\n");
            return;
        }
    }

    const g = ramdisk.findFile(FILE_B) orelse {
        arch.serial.writeString("[SK-43] FAILED: findFile(hello.txt)\n");
        return;
    };
    if (g.size != DATA_B.len or g.data[0] != 's') {
        arch.serial.writeString("[SK-43] FAILED: hello.txt entry\n");
        return;
    }

    if (ramdisk.findFile("missing") != null) {
        arch.serial.writeString("[SK-43] FAILED: missing not rejected\n");
        return;
    }
    const name0 = ramdisk.getFileName(0) orelse {
        arch.serial.writeString("[SK-43] FAILED: getFileName\n");
        return;
    };
    if (name0.len != FILE_A.len) {
        arch.serial.writeString("[SK-43] FAILED: name0 len\n");
        return;
    }

    arch.serial.writeString("[SK-43] shared ramdisk parse: OK\n");
}
