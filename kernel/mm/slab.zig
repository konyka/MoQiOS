/// Kernel slab allocator — multiple size classes for kmalloc/kfree.
/// Uses intrusive free lists within pages allocated from PMM.
/// Each allocation stores a SlabHeader before the returned pointer so that
/// kfree(ptr) can determine the size class without the caller passing it.
///
/// K2: an optional per-CPU magazine layer (slab_mag.zig) sits in front of
/// the size-class pools; see slab_magazine_enable below.
const pmm = @import("pmm.zig");
const hhdm = @import("hhdm.zig");
const serial = @import("../arch/arch.zig").serial;
const arch_irq = @import("../arch/arch.zig").irq;
const syscall_entry = @import("../arch/arch.zig").syscall;
const klog = @import("../klog.zig");
const IrqSpinlock = @import("../sync/irq_spinlock.zig").IrqSpinlock;
const slab_mag = @import("slab_mag.zig");

const PAGE_SIZE: u64 = 4096;

/// Slab size classes (bytes). These are the *payload* sizes — the actual
/// object size in the slab includes the SlabHeader overhead.
const SIZE_CLASSES = [_]usize{ 32, 64, 128, 256, 512, 1024 };
const NUM_CLASSES: usize = SIZE_CLASSES.len;

/// Header prepended to every slab allocation.
/// Stores the pool index so kfree can find the right free list.
const SlabHeader = extern struct {
    pool_idx: u8,
    _pad: u16 = 0,
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
    lock: IrqSpinlock = .{}, // v53.44: SMP-safe free list access
};

/// Global slab pools.
var pools: [NUM_CLASSES]SlabPool = undefined;
var initialized: bool = false;

/// K2: per-CPU magazine layer gate. When false, kmalloc/kfree take the pool
/// lock on every small-class operation — byte-identical to the pre-K2
/// behaviour. When true, small-class allocs/frees go through per-CPU
/// magazines and only touch the pool lock on batch refill/flush.
pub const slab_magazine_enable: bool = true;

/// Magazine array dimension — one magazine per (CPU, size class).
const MAG_CPUS: usize = syscall_entry.MAX_CPUS;

/// K2: per-CPU, per-class magazines. Static, zero-initialised (all empty).
/// A magazine is only ever touched by its owning CPU inside an IRQ-off
/// window, so no lock is needed on the magazines themselves; the pool lock
/// still serialises every refill/flush against other CPUs.
var magazines: [MAG_CPUS][NUM_CLASSES]slab_mag.Magazine =
    [_][NUM_CLASSES]slab_mag.Magazine{[_]slab_mag.Magazine{.{}} ** NUM_CLASSES} ** MAG_CPUS;

/// K2: magazine index for the currently executing CPU. Must be called inside
/// an IRQ-off window (or before per-CPU bring-up, where it returns 0).
///
/// Migration safety: all magazine operations run with IRQs disabled
/// (arch.irq.saveAndDisable). Context switches on this CPU are initiated
/// either by an interrupt (timer tick -> forceReschedule, or a reschedule
/// IPI) or by an explicit blocking/scheduling call — kmalloc/kfree make no
/// such call — so with IRQs off the running CPU cannot change between reading
/// cpu_id and finishing the magazine operation. Magazines are CPU-local
/// state with no address-space ties, so PCID/CR3 switches need no handling.
fn currentMagCpu() usize {
    const pc = syscall_entry.getPerCpuOrNull() orelse return 0; // early boot
    if (pc.cpu_id >= MAG_CPUS) return 0;
    return pc.cpu_id;
}

/// K2: backing-store adapter handed to Magazine.refill/flush. The caller
/// holds the pool lock for the whole batch, so these are plain free-list
/// ops. Magazine-held objects count as pool-allocated: popFree bumps
/// allocated_count, pushFree decrements it — getStats() therefore reports
/// live user allocations plus magazine stock (see getStats doc).
const PoolAdapter = struct {
    pool_idx: usize,

    pub fn popFree(self: *PoolAdapter) ?*anyopaque {
        const pool = &pools[self.pool_idx];
        if (pool.free_list == null) {
            if (!refillPoolLocked(self.pool_idx)) return null;
        }
        const node = pool.free_list.?;
        pool.free_list = node.next;
        pool.allocated_count += 1;
        return @ptrCast(node);
    }

    pub fn pushFree(self: *PoolAdapter, obj: *anyopaque) void {
        const pool = &pools[self.pool_idx];
        const node: *FreeNode = @ptrCast(@alignCast(obj));
        node.next = pool.free_list;
        pool.free_list = node;
        if (pool.allocated_count > 0) {
            pool.allocated_count -= 1;
        }
    }
};

pub fn init() void {
    // Idempotent: SK-6 / subsystem_boot / main may all call this.
    if (initialized) return;
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

/// v53.44: refillPoolLocked — must be called with pool lock held.
fn refillPoolLocked(pool_idx: usize) bool {
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

    if (comptime slab_magazine_enable) {
        return kmallocMag(pool_idx);
    }

    // v53.44: SMP-safe free list access
    const flags = pools[pool_idx].lock.acquire();
    defer pools[pool_idx].lock.release(flags);

    if (pools[pool_idx].free_list == null) {
        if (!refillPoolLocked(pool_idx)) return null;
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

/// K2: magazine fast path for small classes. Local pops are lock-free inside
/// an IRQ-off window; the pool lock is taken only to batch-refill an empty
/// magazine. The pool treats magazine-held objects as allocated, so an
/// object is never handed out twice.
fn kmallocMag(pool_idx: usize) ?*anyopaque {
    const flags = arch_irq.saveAndDisable();
    defer arch_irq.restore(flags);

    const mag = &magazines[currentMagCpu()][pool_idx];
    var slot_opt = mag.pop();
    if (slot_opt == null) {
        // Empty magazine: batch-refill from the pool under the pool lock.
        const pflags = pools[pool_idx].lock.acquire();
        var adapter = PoolAdapter{ .pool_idx = pool_idx };
        _ = mag.refill(&adapter);
        pools[pool_idx].lock.release(pflags);
        slot_opt = mag.pop();
        if (slot_opt == null) return null; // pool OOM
    }
    const slot_ptr: [*]u8 = @ptrCast(slot_opt.?);

    // Write SlabHeader at the start of the slot
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
        // Large allocation — free all contiguous pages
        const pages_count: u64 = header_ptr._pad;
        const virt_base = user_addr - HEADER_ALIGNED;
        const phys_base = hhdm.virtToPhys(virt_base);
        if (pages_count <= 1) {
            pmm.freePage(phys_base);
        } else {
            // Free contiguous pages (phys_base must be page-aligned)
            var p: u64 = 0;
            while (p < pages_count) : (p += 1) {
                pmm.freePage(phys_base + p * PAGE_SIZE);
            }
        }
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

    if (comptime slab_magazine_enable) {
        kfreeMag(pool_idx, user_addr);
        return;
    }

    // v53.44: SMP-safe free list access
    const flags = pools[pool_idx].lock.acquire();
    defer pools[pool_idx].lock.release(flags);

    // Return the slot (including header) to the free list
    const slot_ptr: [*]u8 = @ptrFromInt(user_addr - HEADER_ALIGNED);
    const node: *FreeNode = @ptrCast(@alignCast(slot_ptr));
    node.next = pools[pool_idx].free_list;
    pools[pool_idx].free_list = node;
    if (pools[pool_idx].allocated_count > 0) {
        pools[pool_idx].allocated_count -= 1;
    }
}

/// K2: magazine fast path for small-class frees. The freed slot (including
/// its header) is pushed onto this CPU's magazine; on a full magazine half
/// of the stock is flushed back to the pool under the pool lock, after which
/// the push always fits (FLUSH_BATCH < MAG_SIZE).
fn kfreeMag(pool_idx: usize, user_addr: usize) void {
    const slot_ptr: [*]u8 = @ptrFromInt(user_addr - HEADER_ALIGNED);
    const flags = arch_irq.saveAndDisable();
    defer arch_irq.restore(flags);

    const mag = &magazines[currentMagCpu()][pool_idx];
    if (!mag.push(@ptrCast(slot_ptr))) {
        const pflags = pools[pool_idx].lock.acquire();
        var adapter = PoolAdapter{ .pool_idx = pool_idx };
        _ = mag.flush(&adapter);
        pools[pool_idx].lock.release(pflags);
        _ = mag.push(@ptrCast(slot_ptr));
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
    // The 8-byte header lives inside the returned run of pages, so count it —
    // otherwise kmalloc(4089..4096) got one page and 8 fewer usable bytes
    // than requested.
    const pages_needed = (size + HEADER_ALIGNED + PAGE_SIZE - 1) / PAGE_SIZE;
    // kfree reads the page count from the u16 _pad field; an allocation
    // needing more than 65535 pages would leak the rest on free. Refuse it.
    if (pages_needed > 65535) {
        serial.writeString("[slab] allocation too large, refusing\n");
        return null;
    }
    if (pages_needed == 1) {
        const phys = pmm.allocPage() orelse return null;
        const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
        // Write large alloc marker header
        const header: *SlabHeader = @ptrCast(@alignCast(base));
        header.pool_idx = LARGE_ALLOC_MARKER;
        header._pad = 1; // 1 page for kfree
        // Return pointer after header
        return @ptrFromInt(@intFromPtr(base) + HEADER_ALIGNED);
    }
    // Multi-page allocation: use contiguous pages from PMM
    const phys = pmm.allocContiguous(pages_needed) orelse {
        serial.writeString("[slab] OOM: cannot allocate contiguous pages\n");
        return null;
    };
    const base: [*]u8 = @ptrFromInt(hhdm.physToVirt(phys));
    // Write large alloc marker header with page count for freeing
    const header: *SlabHeader = @ptrCast(@alignCast(base));
    header.pool_idx = LARGE_ALLOC_MARKER;
    // Store page count in _pad field for freeing
    header._pad = @intCast(pages_needed);
    return @ptrFromInt(@intFromPtr(base) + HEADER_ALIGNED);
}

/// K2 stats semantics: with slab_magazine_enable, `total_allocs` counts all
/// objects checked out of the pool free lists — live user allocations PLUS
/// per-CPU magazine stock (at most MAG_SIZE per online CPU per class). It is
/// therefore an upper bound on live allocations; with the gate off it is the
/// exact live count, as before. `total_pages` is unaffected by magazines.
pub fn getStats() struct { total_allocs: u32, total_pages: u32 } {
    var allocs: u32 = 0;
    var pages: u32 = 0;
    for (0..NUM_CLASSES) |i| {
        // v53.44: acquire lock for safe counter read
        const flags = pools[i].lock.acquire();
        allocs += pools[i].allocated_count;
        pages += pools[i].page_count;
        pools[i].lock.release(flags);
    }
    return .{ .total_allocs = allocs, .total_pages = pages };
}
