//! Host-testable policy for task-lifetime operation pins.

pub const MAX_OPERATION_REFS: u32 = 1024;

pub const PinError = error{ Zombie, NoMm, OperationRefOverflow };

pub const Candidate = struct {
    tid: u32,
    zombie: bool = false,
    mm_available: bool = true,
    operation_refs: u32 = 0,
};

pub const Selection = union(enum) {
    selected: usize,
    task_not_found,
    zombie,
    no_mm,
    operation_ref_overflow,
};

/// Mirrors the locked kernel lookup order without importing architecture code.
pub fn select(candidates: []const Candidate, tid: u32) Selection {
    var saw_zombie = false;
    for (candidates, 0..) |candidate, index| {
        if (candidate.tid != tid) continue;
        if (candidate.zombie) {
            saw_zombie = true;
            continue;
        }
        if (candidate.operation_refs >= MAX_OPERATION_REFS) return .operation_ref_overflow;
        if (!candidate.mm_available) return .no_mm;
        return .{ .selected = index };
    }
    return if (saw_zombie) .zombie else .task_not_found;
}

pub const State = struct {
    zombie: bool = false,
    reaped: bool = false,
    mm_available: bool = true,
    operation_refs: u32 = 0,

    pub fn pin(self: *State) PinError!void {
        if (self.reaped or self.zombie) return error.Zombie;
        if (self.operation_refs >= MAX_OPERATION_REFS) return error.OperationRefOverflow;
        if (!self.mm_available) return error.NoMm;
        self.operation_refs += 1;
    }

    pub fn release(self: *State) bool {
        if (self.operation_refs == 0) return false;
        self.operation_refs -= 1;
        return true;
    }

    pub fn reap(self: *State) bool {
        if (!self.zombie or self.operation_refs != 0 or self.reaped) return false;
        self.reaped = true;
        return true;
    }
};
