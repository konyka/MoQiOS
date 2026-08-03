//! Pure PCID (Process-Context Identifier) bookkeeping — host-testable, no
//! imports, no arch dependencies. The x86_64 glue in
//! kernel/arch/x86_64/pcid.zig wraps this core with CPUID probing, CR4.PCIDE,
//! INVPCID and a lock; everything racy is expressed with atomics here so the
//! same code runs unmodified on the host test target.
//!
//! Model:
//!   - PCID 0 is reserved: kernel PML4 and any unregistered address space
//!     use it, which means "legacy CR3 write, flush everything".
//!   - Each user address space (one PML4 root) gets one PCID at creation and
//!     returns it at destruction.
//!   - Every PCID carries an invalidation generation. It is bumped when the
//!     owner is unregistered (the ID may be recycled) and on every TLB
//!     shootdown targeting the owning space. A CPU that holds cached entries
//!     for a PCID it is not currently running compares its recorded
//!     generation against the live one: a mismatch forces a flushing CR3
//!     write, which is what makes PCID reuse and missed shootdowns safe.

/// Reserved PCID: kernel half / "no PCID" legacy semantics.
pub const PCID_KERNEL: u16 = 0;
pub const FIRST_USER_PCID: u16 = 1;
/// 12-bit PCID space (CR3 bits 11:0 when CR4.PCIDE = 1).
pub const MAX_PCID: u16 = 4095;

/// Live address spaces are bounded by the task table (MAX_TASKS = 64); the
/// registry never needs more slots than that.
pub const MAX_SPACES: usize = 64;

pub const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;
/// CR3 bit 63: with CR4.PCIDE = 1 a MOV to CR3 with this bit set switches
/// the PCID without invalidating that PCID's TLB entries.
pub const CR3_NO_FLUSH: u64 = 1 << 63;

/// Compose a CR3 value from a PML4 physical address, a PCID and the
/// no-flush bit. With PCIDE = 0 the low 12 bits and bit 63 are ignored by
/// the CPU (bit 63 reserved — callers must only set it when PCIDE = 1).
pub fn composeCr3(pml4_phys: u64, pcid: u16, no_flush: bool) u64 {
    var v = pml4_phys & ADDR_MASK;
    v |= @as(u64, pcid & 0x0FFF);
    if (no_flush) v |= CR3_NO_FLUSH;
    return v;
}

pub const SwitchAction = enum {
    /// CR3 already holds this exact (pml4, pcid) — no write at all.
    skip,
    /// Legacy write (bit 63 clear): invalidates the target PCID's entries.
    flush,
    /// PCID write with bit 63 set: keep the target PCID's cached entries.
    no_flush,
};

/// Decide how to load CR3 for a switch into (target_cr3, target_pcid).
/// `cur_*` describes what this CPU has loaded now; `prev_*` is the last user
/// context this CPU switched away from (a single-slot A→B→A cache);
/// `target_gen` is the target PCID's current invalidation generation.
pub fn decideSwitch(
    cur_pcid: u16,
    cur_cr3: u64,
    prev_pcid: u16,
    prev_gen: u64,
    target_cr3: u64,
    target_pcid: u16,
    target_gen: u64,
) SwitchAction {
    if (target_pcid == PCID_KERNEL) return .flush;
    if (cur_pcid == target_pcid and cur_cr3 == target_cr3) return .skip;
    if (prev_pcid == target_pcid and prev_gen == target_gen) return .no_flush;
    return .flush;
}

/// 12-bit PCID allocator: hands out IDs 1..4095; 0 is permanently reserved.
/// First-fit over a 4096-bit bitmap with a rotating hint.
pub const PcidAllocator = struct {
    // Bit N set ⇔ PCID N in use. Bit 0 starts set: PCID 0 is never handed out.
    words: [64]u64 = [_]u64{1} ++ [_]u64{0} ** 63,
    hint: u16 = FIRST_USER_PCID,

    pub fn alloc(self: *PcidAllocator) ?u16 {
        var n: u16 = 0;
        while (n < MAX_PCID) : (n += 1) {
            // Rotate through 1..4095 starting at the hint.
            const pcid: u16 = (self.hint - 1 + n) % MAX_PCID + 1;
            const word = pcid >> 6;
            const bit: u6 = @intCast(pcid & 63);
            if ((self.words[word] >> bit) & 1 == 0) {
                self.words[word] |= @as(u64, 1) << bit;
                self.hint = if (pcid == MAX_PCID) FIRST_USER_PCID else pcid + 1;
                return pcid;
            }
        }
        return null;
    }

    /// Free a previously allocated PCID. Freeing PCID 0 is ignored (it is
    /// reserved); freeing an unallocated ID is a caller bug (double-free)
    /// and silently keeps the bitmap consistent with "not allocated".
    pub fn free(self: *PcidAllocator, pcid: u16) void {
        if (pcid == PCID_KERNEL or pcid > MAX_PCID) return;
        self.words[pcid >> 6] &= ~(@as(u64, 1) << @intCast(pcid & 63));
        if (pcid < self.hint) self.hint = pcid;
    }

    pub fn isAllocated(self: *const PcidAllocator, pcid: u16) bool {
        return (self.words[pcid >> 6] >> @intCast(pcid & 63)) & 1 != 0;
    }
};

pub const SpaceEntry = struct {
    pml4: u64 = 0,
    pcid: u16 = 0,
    used: bool = false,
};

/// Address-space registry: pml4_phys → PCID, plus the per-PCID invalidation
/// generations. Generations use atomics because the shootdown initiator
/// bumps them while other CPUs read them mid-context-switch; the space table
/// itself is only mutated under the glue layer's registry lock.
pub const PcidCore = struct {
    allocator: PcidAllocator = .{},
    gen: [MAX_PCID + 1]u64 = [_]u64{0} ** (MAX_PCID + 1),
    spaces: [MAX_SPACES]SpaceEntry = [_]SpaceEntry{.{}} ** MAX_SPACES,

    /// Assign a PCID to a new address space. Returns null when the registry
    /// or the PCID space is exhausted — the caller then runs the space as
    /// unregistered (PCID 0, legacy flush-on-switch), which is always safe.
    pub fn registerSpace(self: *PcidCore, pml4_phys: u64) ?u16 {
        if (self.pcidFor(pml4_phys)) |existing| return existing;
        for (&self.spaces) |*e| {
            if (e.used) continue;
            const pcid = self.allocator.alloc() orelse return null;
            e.* = .{ .pml4 = pml4_phys, .pcid = pcid, .used = true };
            return pcid;
        }
        return null;
    }

    /// Drop a space's registration, free its PCID and bump that PCID's
    /// generation so every CPU's cached no-flush record for it is poisoned.
    /// Returns the freed PCID so the glue can INVPCID it locally.
    pub fn unregisterSpace(self: *PcidCore, pml4_phys: u64) ?u16 {
        for (&self.spaces) |*e| {
            if (!e.used or e.pml4 != pml4_phys) continue;
            const pcid = e.pcid;
            e.* = .{};
            self.allocator.free(pcid);
            _ = @atomicRmw(u64, &self.gen[pcid], .Add, 1, .acq_rel);
            return pcid;
        }
        return null;
    }

    pub fn pcidFor(self: *const PcidCore, pml4_phys: u64) ?u16 {
        for (&self.spaces) |*e| {
            if (e.used and e.pml4 == pml4_phys) return e.pcid;
        }
        return null;
    }

    pub fn generation(self: *const PcidCore, pcid: u16) u64 {
        return @atomicLoad(u64, &self.gen[pcid], .acquire);
    }

    /// A TLB shootdown targeted `target_cr3`: CPUs that are NOT currently
    /// running that space keep stale entries for its PCID and are excluded
    /// from the IPI mask, so the generation must move to force a flushing
    /// CR3 write the next time they switch into this space.
    pub fn noteShootdown(self: *PcidCore, target_cr3: u64) void {
        const pcid = self.pcidFor(target_cr3) orelse return;
        _ = @atomicRmw(u64, &self.gen[pcid], .Add, 1, .acq_rel);
    }
};
