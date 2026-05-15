/// Kernel slab allocator — multiple size classes for kmalloc/kfree.
/// Uses intrusive free lists within pages allocated from PMM.
/// Each allocation stores a SlabHeader before the returned pointer so that
/// kfree(ptr) can determine the size class without the caller passing it.

const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");

const PAGE_SIZE: u64 = 4096;

/// Slab size classes (bytes). These are the *payload* sizes — the actual
/// object size in the slab includes the SlabHeader overhead.
const SIZE_CLASSES = [_]usize{ 32, 64, 128, 256, 512, 1024 };
const NUM_CLASSES: usize = SIZE_CLASSES.len;

/// Header prepended to every slab allocation.
/// Stores the pool index so kfree can find the right free list.
const SlabHeader = extern struct {
    pool_idx: u8,
    _pad: u8 = 0,
};

/// Marker for large (direct-page) allocations.
const LARGE_ALLOC_MARKER: u8 = 0xFF;

const HEADER_SIZE: usize = @sizeOf(SlabHeader);
/// Ensure minimum alignment so SlabHeader is always properly aligned.
const HEADER_ALIGNED: usize = if (HEADER_SIZE >= 8) HEADER_SIZE else 8;

/// Free list node — embedded in free objects (stored AFTER the SlabHeader).
const FreeNode = extern struct {
    next: ?*FreeNode,
};

/// Per-class slab pool.
const SlabPool = struct {
    object_size: usize,
    objects_per_page: u32,
    free_list: ?*FreeNode,
    page_count: u32,
    allocated_count: u32,
};

/// Global slab pools.
var pools: [NUM_CLASSES]SlabPool = undefined;
var initialized: bool = false;

pub fn init() void {
    for (0..NUM_CLASSES) |i| {
        const payload_size = SIZE_CLASSES[i];
        // Total slot size: header + payload, aligned to 8 bytes
        const slot_size = (HEADER_ALIGNED + payload_size + 7) & ~@as(usize, 7);
        const free_node_size = @sizeOf(FreeNode);
        const effective_size = if (slot_size >= free_node_size) slot_size else free_node_size;
        pools[i] = .{
            .object_size = effective_size,
            .objects_per_page = @intCast(PAGE_SIZE / effective_size),
            .free_list = null,
            .page_count = 0,
            .allocated_count = 0,
        };
    }
    initialized = true;
    klog.log(.info, "Slab allocator initialized");
}

fn findPool(size: usize) ?usize {
    for (0..NUM_CLASSES) |i| {
        if (size <= SIZE_CLASSES[i]) return i;
    }
    return null;
}

fn refillPool(pool_idx: usize) bool {
    var pool = &pools[pool_idx];
    const phys = pmm.allocPage() orelse {
        serial.writeString("[slab] OOM: cannot allocate page\n");
        return false;
    };
    const page: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));

    var offset: usize = 0;
    while (offset + pool.object_size <= PAGE_SIZE) {
        const node: *FreeNode = @ptrCast(@alignCast(page + offset));
        node.next = pool.free_list;
        pool.free_list = node;
        offset += pool.object_size;
    }

    pool.page_count += 1;
    return true;
}

pub fn kmalloc(size: usize) ?*anyopaque {
    if (!initialized) return null;

    const pool_idx = findPool(size) orelse {
        return allocLarge(size);
    };

    if (pools[pool_idx].free_list == null) {
        if (!refillPool(pool_idx)) return null;
    }

    const node = pools[pool_idx].free_list.?;
    pools[pool_idx].free_list = node.next;
    pools[pool_idx].allocated_count += 1;

    // Write SlabHeader at the start of the slot
    const slot_ptr: [*]u8 = @ptrCast(node);
    const header: *SlabHeader = @ptrCast(@alignCast(slot_ptr));
    header.pool_idx = @intCast(pool_idx);

    // Zero the payload area (after header)
    const payload: [*]u8 = slot_ptr + HEADER_ALIGNED;
    const payload_len = pools[pool_idx].object_size - HEADER_ALIGNED;
    @memset(payload[0..payload_len], 0);

    // Return pointer to payload (after header)
    return @ptrFromInt(@intFromPtr(slot_ptr) + HEADER_ALIGNED);
}

pub fn kfree(ptr: *anyopaque) void {
    if (!initialized) return;

    // Read SlabHeader immediately before the user pointer
    const user_addr = @intFromPtr(ptr);
    const header_ptr: *const SlabHeader = @ptrCast(@alignCast(@as([*]const u8, @ptrCast(ptr)) - HEADER_ALIGNED));
    const pool_idx = header_ptr.pool_idx;

    if (pool_idx == LARGE_ALLOC_MARKER) {
        // Large allocation — free the page
        const phys = hhdm.virtToPhys(user_addr);
        pmm.freePage(phys);
        return;
    }

    if (pool_idx >= NUM_CLASSES) {
        serial.writeString("[slab] BUG: kfree with corrupt header, pool_idx=");
        var buf: [4]u8 = undefined;
        buf[0] = pool_idx + '0';
        serial.writeString(buf[0..1]);
        serial.writeString("\n");
        return;
    }

    // Return the slot (including header) to the free list
    const slot_ptr: [*]u8 = @ptrFromInt(user_addr - HEADER_ALIGNED);
    const node: *FreeNode = @ptrCast(@alignCast(slot_ptr));
    node.next = pools[pool_idx].free_list;
    pools[pool_idx].free_list = node;
    if (pools[pool_idx].allocated_count > 0) {
        pools[pool_idx].allocated_count -= 1;
    }
}

pub fn krealloc(ptr: ?*anyopaque, old_size: usize, new_size: usize) ?*anyopaque {
    if (ptr == null) return kmalloc(new_size);
    if (new_size == 0) {
        kfree(ptr.?);
        return null;
    }
    const new_ptr = kmalloc(new_size) orelse return null;
    // Copy min(old_size, new_size) bytes
    const copy_len = @min(old_size, new_size);
    const src: [*]const u8 = @ptrCast(ptr.?);
    const dst: [*]u8 = @ptrCast(new_ptr.?);
    @memcpy(dst[0..copy_len], src[0..copy_len]);
    kfree(ptr.?);
    return new_ptr;
}

fn allocLarge(size: usize) ?*anyopaque {
    const pages_needed = (size + PAGE_SIZE - 1) / PAGE_SIZE;
    if (pages_needed == 1) {
        const phys = pmm.allocPage() orelse return null;
        const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
        // Write large alloc marker header
        const header: *SlabHeader = @ptrCast(@alignCast(base));
        header.pool_idx = LARGE_ALLOC_MARKER;
        // Return pointer after header
        return @ptrFromInt(@intFromPtr(base) + HEADER_ALIGNED);
    }
    serial.writeString("[slab] Large multi-page alloc not yet supported\n");
    return null;
}

pub fn getStats() struct { total_allocs: u32, total_pages: u32 } {
    var allocs: u32 = 0;
    var pages: u32 = 0;
    for (0..NUM_CLASSES) |i| {
        allocs += pools[i].allocated_count;
        pages += pools[i].page_count;
    }
    return .{ .total_allocs = allocs, .total_pages = pages };
}
