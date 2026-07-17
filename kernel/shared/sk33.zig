//! SK-33 — shared page_cache boot fragment.
//!
//! Proves `subsystem_boot.initPageCache` matches `main.zig`'s M7 page_cache
//! call, then insert/read/invalidate a probe page via shared PMM/HHDM.

const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");
const page_cache = @import("../fs/page_cache.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");

const PROBE_INODE: u64 = 0x5333;

pub fn announce() void {
    subsystem_boot.initPageCache();

    const phys = pmm.allocPage() orelse {
        arch.serial.writeString("[SK-33] FAILED: allocPage\n");
        return;
    };
    const data: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    data[0] = 0x33;
    data[1] = 0xA5;

    _ = page_cache.insertPageOwned(PROBE_INODE, 0, phys, 2) orelse {
        pmm.freePage(phys);
        arch.serial.writeString("[SK-33] FAILED: insertPageOwned\n");
        return;
    };

    if (!page_cache.isCached(PROBE_INODE, 0)) {
        arch.serial.writeString("[SK-33] FAILED: isCached miss\n");
        page_cache.invalidateInode(PROBE_INODE);
        return;
    }

    const hit = page_cache.readPage(PROBE_INODE, 0) orelse {
        arch.serial.writeString("[SK-33] FAILED: readPage miss\n");
        page_cache.invalidateInode(PROBE_INODE);
        return;
    };
    if (hit[0] != 0x33 or hit[1] != 0xA5) {
        arch.serial.writeString("[SK-33] FAILED: page R/W\n");
        page_cache.invalidateInode(PROBE_INODE);
        return;
    }

    page_cache.invalidateInode(PROBE_INODE);
    if (page_cache.isCached(PROBE_INODE, 0)) {
        arch.serial.writeString("[SK-33] FAILED: invalidate\n");
        return;
    }

    arch.serial.writeString("[SK-33] shared page_cache boot: OK\n");
}
