//! SK-34 — shared tmpfs + random boot fragments.
//!
//! Proves `subsystem_boot.initTmpfs` / `initRandom` match `main.zig`, with
//! random entropy from `arch.tsc.read` (not x86 `rdtsc`).

const arch = @import("../arch/arch.zig");
const subsystem_boot = @import("subsystem_boot.zig");
const tmpfs = @import("../fs/tmpfs.zig");
const random = @import("../drivers/random.zig");

pub fn announce() void {
    subsystem_boot.initTmpfs();
    subsystem_boot.initRandom();

    const idx_i = tmpfs.tmpfsOpen("/tmp/sk34", true, false);
    if (idx_i < 0) {
        arch.serial.writeString("[SK-34] FAILED: tmpfsOpen\n");
        return;
    }
    const idx: u8 = @intCast(idx_i);
    const payload = "SK34";
    const wrote = tmpfs.tmpfsWrite(idx, 0, payload.ptr, payload.len);
    if (wrote != @as(i64, @intCast(payload.len))) {
        arch.serial.writeString("[SK-34] FAILED: tmpfsWrite\n");
        _ = tmpfs.tmpfsUnlink("/tmp/sk34");
        return;
    }
    var rbuf: [4]u8 = undefined;
    const nread = tmpfs.tmpfsRead(idx, 0, &rbuf, 4);
    if (nread != 4 or rbuf[0] != 'S' or rbuf[1] != 'K' or rbuf[2] != '3' or rbuf[3] != '4') {
        arch.serial.writeString("[SK-34] FAILED: tmpfsRead\n");
        _ = tmpfs.tmpfsUnlink("/tmp/sk34");
        return;
    }
    if (tmpfs.tmpfsUnlink("/tmp/sk34") < 0) {
        arch.serial.writeString("[SK-34] FAILED: tmpfsUnlink\n");
        return;
    }

    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    random.getRandomBytes(&a, 8);
    random.getRandomBytes(&b, 8);
    var same: bool = true;
    for (0..8) |i| {
        if (a[i] != b[i]) same = false;
    }
    if (same) {
        arch.serial.writeString("[SK-34] FAILED: random stuck\n");
        return;
    }

    arch.serial.writeString("[SK-34] shared tmpfs+random boot: OK\n");
}
