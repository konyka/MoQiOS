/// Kernel virtual address space manager.
/// Tracks which virtual address ranges are mapped in the kernel.

const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");

pub const KERNEL_BASE: u64 = 0xFFFFFFFF80000000;

pub const AddressRange = struct {
    start: u64,
    end: u64,
    writable: bool,
    executable: bool,

    pub inline fn size(self: AddressRange) u64 {
        return self.end - self.start;
    }
};

var ranges: [64]AddressRange = undefined;
var range_count: u32 = 0;

pub fn init() void {
    range_count = 0;
    klog.log(.info, "Address space manager initialized");
}

pub fn addRange(start: u64, end: u64, writable: bool, executable: bool) void {
    if (range_count >= 64) {
        serial.writeString("[addr_space] FATAL: too many ranges\n");
        return;
    }
    ranges[range_count] = .{
        .start = start,
        .end = end,
        .writable = writable,
        .executable = executable,
    };
    range_count += 1;
}

pub fn findRange(addr: u64) ?AddressRange {
    for (0..range_count) |i| {
        if (addr >= ranges[i].start and addr < ranges[i].end) {
            return ranges[i];
        }
    }
    return null;
}

pub fn getRangeCount() u32 {
    return range_count;
}
