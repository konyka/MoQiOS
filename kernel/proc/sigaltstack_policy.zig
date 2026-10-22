//! Pure sigaltstack(2) rules (Linux x86-64 semantics).
//!
//! An alternate stack is used for a handler installed with SA_ONSTACK,
//! unless the task is already running on it (nested delivery stays on the
//! current stack). While on the stack it cannot be changed (EPERM).

pub const SS_ONSTACK: u32 = 1;
pub const SS_DISABLE: u32 = 2;
pub const MINSIGSTKSZ: u64 = 2048;
pub const SA_ONSTACK: u64 = 0x0800_0000;

pub const EPERM: i64 = -1;
pub const EINVAL: i64 = -22;
pub const ENOMEM: i64 = -12;

pub const AltStack = struct {
    base: u64 = 0,
    size: u64 = 0,

    pub fn enabled(self: AltStack) bool {
        return self.size != 0;
    }
};

/// Linux on_sig_stack: the stack occupies (base, base + size].
pub fn onStack(rsp: u64, alt: AltStack) bool {
    if (!alt.enabled()) return false;
    return rsp > alt.base and rsp - alt.base <= alt.size;
}

/// ss_flags reported for the current state.
pub fn currentFlags(rsp: u64, alt: AltStack) u32 {
    if (!alt.enabled()) return SS_DISABLE;
    return if (onStack(rsp, alt)) SS_ONSTACK else 0;
}

/// Validate a new stack_t. Returns the stack to install or an errno.
pub fn set(rsp: u64, current: AltStack, sp: u64, flags: u32, size: u64) union(enum) { ok: AltStack, err: i64 } {
    if (onStack(rsp, current)) return .{ .err = EPERM };
    // SS_ONSTACK is accepted as an alias of 0 (older glibc passes it).
    switch (flags) {
        SS_DISABLE => return .{ .ok = .{} },
        0, SS_ONSTACK => {},
        else => return .{ .err = EINVAL },
    }
    if (size < MINSIGSTKSZ) return .{ .err = ENOMEM };
    if (sp > ~@as(u64, 0) - size) return .{ .err = EINVAL };
    return .{ .ok = .{ .base = sp, .size = size } };
}

/// Stack top the signal frame is pushed below.
pub fn deliveryTop(user_rsp: u64, sa_flags: u64, alt: AltStack) u64 {
    if (sa_flags & SA_ONSTACK == 0) return user_rsp;
    if (!alt.enabled() or onStack(user_rsp, alt)) return user_rsp;
    return alt.base + alt.size;
}
