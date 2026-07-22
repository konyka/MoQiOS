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
    @import("sk42.zig").announce();
    @import("sk43.zig").announce();
    @import("sk44.zig").announce();
    @import("sk45.zig").announce();
    @import("sk46.zig").announce();
    @import("sk47.zig").announce();
    @import("sk48.zig").announce();
    @import("sk49.zig").announce();
    @import("sk50.zig").announce();
    @import("sk51.zig").announce();
    @import("sk52.zig").announce();
    @import("sk53.zig").announce();
    @import("sk54.zig").announce();
    @import("sk55.zig").announce();
    @import("sk56.zig").announce();
    @import("sk57.zig").announce();
    @import("sk58.zig").announce();
    @import("sk59.zig").announce();
    @import("sk60.zig").announce();
    @import("sk61.zig").announce();
    @import("sk62.zig").announce();
    @import("sk63.zig").announce();
    @import("sk64.zig").announce();
    @import("sk65.zig").announce();
    @import("sk66.zig").announce();
    @import("sk67.zig").announce();
    @import("sk68.zig").announce();
    @import("sk69.zig").announce();
    @import("sk70.zig").announce();
    @import("sk71.zig").announce();
    @import("sk72.zig").announce();
    @import("sk73.zig").announce();
    @import("sk74.zig").announce();
    @import("sk75.zig").announce();
}
