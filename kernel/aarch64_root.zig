//! Build root for `-Darch=aarch64`.
//!
//! Lives under `kernel/` so the module can import shared code (`klog`, `panic`,
//! `shared/sk2.zig`) that the arch skeleton pulls in. The real `_start` lives in
//! `arch/aarch64/start.zig`.

pub const panic = @import("panic.zig").panic;

comptime {
    _ = @import("arch/aarch64/start.zig");
}
