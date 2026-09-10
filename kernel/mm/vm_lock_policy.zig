//! Pure decisions for the current-task VM mutation guard.

pub const Decision = enum {
    no_mm,
    acquire,
    recursive,
};

pub fn decide(has_mm: bool, already_held: bool) Decision {
    if (!has_mm) return .no_mm;
    if (already_held) return .recursive;
    return .acquire;
}
