//! Pure policy for the fallocate modes implemented by MoQiOS.

pub const MODE_DEFAULT: u32 = 0;
pub const EOPNOTSUPP: i64 = -95;

/// Validate mode before fallocate looks up or mutates the target file.
pub fn validate(mode: u32) i64 {
    if (mode == MODE_DEFAULT) return 0;
    return EOPNOTSUPP;
}
