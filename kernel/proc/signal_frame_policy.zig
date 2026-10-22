//! Pure placement of the user-stack signal frame (x86-64 SysV ABI).
//!
//! Layout below the interrupted RSP, stack growing down:
//!   [user_rsp - RED_ZONE, user_rsp)   red zone, never touched
//!   [handler_rsp + 8, +8 + frame_size) saved context (SignalFrame)
//!   [handler_rsp, handler_rsp + 8)     return address (sigreturn trampoline)
//! The handler is entered with RSP = handler_rsp, which satisfies the ABI
//! entry rule (RSP + 8) % 16 == 0.

pub const RED_ZONE: u64 = 128;

/// Handler entry RSP for a frame of `frame_size` bytes pushed below
/// `user_rsp`, or null when the stack has no room (the arithmetic would
/// wrap below zero).
pub fn handlerRsp(user_rsp: u64, frame_size: u64) ?u64 {
    const need = RED_ZONE + frame_size + 8 + 8 + 15;
    if (user_rsp < need) return null;
    const limit = user_rsp - RED_ZONE;
    const unaligned = limit - frame_size - 8 - 8;
    return (unaligned & ~@as(u64, 15)) + 8;
}
