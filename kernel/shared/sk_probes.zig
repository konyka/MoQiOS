//! Shared SK announce ladder for non-x86 bring-up (SK-32+).
//!
//! Keeps riscv64/aarch64 `start.zig` in sync: early probes before the shared
//! PMM carve, then sk6..skN after identity map + arena are live.

/// Before arch PMM / MMU bring-up (serial + shared fmt only).
pub fn runEarly() void {
    @import("sk2.zig").announce();
    @import("sk3.zig").announce();
    @import("sk4.zig").announce();
}

/// After shared mm carve: sk6(arena) then sk7..sk37 (sk36 cleanup, sk37 footprint).
pub fn runPostMm(phys_base: u64, length: u64) void {
    @import("sk6.zig").announce(phys_base, length);
    @import("sk7.zig").announce();
    @import("sk8.zig").announce();
    @import("sk9.zig").announce();
    @import("sk10.zig").announce();
    @import("sk11.zig").announce();
    @import("sk12.zig").announce();
    @import("sk13.zig").announce();
    @import("sk14.zig").announce();
    @import("sk15.zig").announce();
    @import("sk17.zig").announce();
    @import("sk18.zig").announce();
    @import("sk19.zig").announce();
    @import("sk20.zig").announce();
    @import("sk21.zig").announce();
    @import("sk22.zig").announce();
    @import("sk23.zig").announce();
    @import("sk24.zig").announce();
    @import("sk25.zig").announce();
    @import("sk26.zig").announce();
    @import("sk27.zig").announce();
    @import("sk28.zig").announce();
    @import("sk29.zig").announce();
    @import("sk30.zig").announce();
    @import("sk31.zig").announce();
    @import("sk32.zig").announce();
    @import("sk33.zig").announce();
    @import("sk34.zig").announce();
    @import("sk35.zig").announce();
    @import("sk36.zig").announce();
    @import("sk37.zig").announce();
    @import("sk38.zig").announce();
    @import("sk39.zig").announce();
    @import("sk40.zig").announce();
}
