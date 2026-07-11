//! Minimal Flattened Device Tree (FDT/DTB) walker for early aarch64 bring-up.
//!
//! Milestone 9-3 only needs `/memory` `reg` regions. Parent `#address-cells` /
//! `#size-cells` are tracked on a nesting stack so `/soc` overrides do not
//! corrupt root-level `memory@…` parsing.

pub const MAGIC: u32 = 0xd00dfeed;

pub const MemRegion = struct {
    base: u64,
    size: u64,
};

fn readBe32(addr: usize) u32 {
    const p: [*]const u8 = @ptrFromInt(addr);
    return (@as(u32, p[0]) << 24) |
        (@as(u32, p[1]) << 16) |
        (@as(u32, p[2]) << 8) |
        @as(u32, p[3]);
}

fn cstrLen(p: [*:0]const u8) usize {
    var n: usize = 0;
    while (p[n] != 0) : (n += 1) {}
    return n;
}

fn startsWith(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return stdMemEql(s[0..prefix.len], prefix);
}

fn stdMemEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// Parse DTB and fill `out` with memory regions. Returns the number written.
pub fn findMemoryRegions(dtb: usize, out: []MemRegion) usize {
    if (dtb == 0) return 0;
    if (readBe32(dtb) != MAGIC) return 0;

    const off_dt_struct = readBe32(dtb + 8);
    const off_dt_strings = readBe32(dtb + 12);
    const struct_base = dtb + off_dt_struct;
    const strings_base = dtb + off_dt_strings;

    // Per-nesting-level cells. Child `reg` uses the *parent* level.
    // Initialise in a loop — `.{2} ** 16` can emit NEON loads from a
    // misaligned rodata blob and Data-Abort on aarch64.
    var addr_stack: [16]u32 = undefined;
    var size_stack: [16]u32 = undefined;
    for (&addr_stack) |*e| e.* = 2;
    for (&size_stack) |*e| e.* = 1;
    var depth: usize = 0;
    var count: usize = 0;
    var in_memory = false;
    var p = struct_base;

    while (true) {
        const token = readBe32(p);
        p += 4;
        switch (token) {
            0x1 => { // FDT_BEGIN_NODE
                const name_ptr: [*:0]const u8 = @ptrFromInt(p);
                const name_len = cstrLen(name_ptr);
                const name = name_ptr[0..name_len];
                in_memory = startsWith(name, "memory");
                if (depth + 1 < addr_stack.len) {
                    addr_stack[depth + 1] = addr_stack[depth];
                    size_stack[depth + 1] = size_stack[depth];
                    depth += 1;
                }
                p = (p + name_len + 1 + 3) & ~@as(usize, 3);
            },
            0x2 => { // FDT_END_NODE
                in_memory = false;
                if (depth > 0) depth -= 1;
            },
            0x3 => { // FDT_PROP
                const len = readBe32(p);
                const nameoff = readBe32(p + 4);
                p += 8;
                const prop_name_ptr: [*:0]const u8 = @ptrFromInt(strings_base + nameoff);
                const prop_name = prop_name_ptr[0..cstrLen(prop_name_ptr)];
                const data = p;
                if (stdMemEql(prop_name, "#address-cells") and len == 4) {
                    addr_stack[depth] = readBe32(data);
                } else if (stdMemEql(prop_name, "#size-cells") and len == 4) {
                    size_stack[depth] = readBe32(data);
                } else if (in_memory and stdMemEql(prop_name, "reg")) {
                    const p_addr = if (depth > 0) addr_stack[depth - 1] else addr_stack[depth];
                    const p_size = if (depth > 0) size_stack[depth - 1] else size_stack[depth];
                    const entry_bytes = (p_addr + p_size) * 4;
                    if (entry_bytes != 0) {
                        var off: u32 = 0;
                        while (off + entry_bytes <= len and count < out.len) : (off += entry_bytes) {
                            var base: u64 = 0;
                            var size: u64 = 0;
                            var i: u32 = 0;
                            while (i < p_addr) : (i += 1) {
                                base = (base << 32) | readBe32(data + off + i * 4);
                            }
                            i = 0;
                            while (i < p_size) : (i += 1) {
                                size = (size << 32) | readBe32(data + off + (p_addr + i) * 4);
                            }
                            if (size != 0) {
                                out[count] = .{ .base = base, .size = size };
                                count += 1;
                            }
                        }
                    }
                }
                p = (p + len + 3) & ~@as(usize, 3);
            },
            0x4 => {}, // FDT_NOP
            0x9 => return count, // FDT_END
            else => return count,
        }
    }
}
