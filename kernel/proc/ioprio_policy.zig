//! Pure ioprio encoding and target-selection policy.

pub const WHO_PROCESS: u32 = 1;
pub const CLASS_RT: u32 = 1;
pub const CLASS_BE: u32 = 2;
pub const CLASS_IDLE: u32 = 3;
pub const DEFAULT: u32 = (CLASS_BE << 13) | 4;

pub fn validWhich(which: u32) bool {
    return which == WHO_PROCESS;
}

pub fn unsupportedWhich(which: u32) bool {
    return which == 2 or which == 3;
}

pub fn validValue(value: u32) bool {
    if ((value & ~@as(u32, 0x7FFF)) != 0) return false;
    const class = value >> 13;
    const data = value & 0x1FFF;
    return switch (class) {
        CLASS_RT, CLASS_BE => data <= 7,
        CLASS_IDLE => data == 0,
        else => false,
    };
}
