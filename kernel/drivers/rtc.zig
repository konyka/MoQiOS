/// RTC wall clock (x86 CMOS RTC, ports 0x70/0x71).
///
/// At boot the RTC date/time registers are read once and converted to a
/// Unix epoch base; from then on the wall clock is that base plus the
/// TSC-monotonic time since boot (proc/time_syscall.zig wall_clock_offset),
/// so gettimeofday/clock_gettime(CLOCK_REALTIME) never touch the RTC again.
///
/// Century rule: the RTC year register is 2-digit BCD. Values 00-69 map to
/// 2000-2069, values 70-99 map to 1970-1999 (the classic Unix pivot). The
/// CMOS century register (0x32) is deliberately not trusted — QEMU and most
/// firmware leave it unset.
///
/// The pure conversion logic (bcdToBin / isLeapYear / daysFromCivil /
/// expandYear / dateTimeToEpoch) has no kernel imports and is host-tested
/// via tests/main.zig (wired through kernel/host_test.zig).

/// BCD byte → binary (0x59 → 59). Garbage nibbles wrap mod 100.
pub fn bcdToBin(bcd: u8) u8 {
    return (bcd >> 4) *% 10 +% (bcd & 0x0F);
}

pub fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

/// 2-digit RTC year → full year (see the century rule above).
pub fn expandYear(yy: u8) u16 {
    return if (yy < 70) 2000 + @as(u16, yy) else 1900 + @as(u16, yy);
}

/// Days since 1970-01-01 for a Gregorian date (Howard Hinnant's
/// days_from_civil). Valid for the full expandYear range.
pub fn daysFromCivil(y_in: u16, m: u8, d: u8) i64 {
    var y: i64 = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe: i64 = y - era * 400; // [0, 399]
    const mp: i64 = @mod(@as(i64, m) + 9, 12); // Mar=0 ... Feb=11
    const doy: i64 = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe: i64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Gregorian date + time-of-day → Unix epoch seconds.
pub fn dateTimeToEpoch(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) u64 {
    const days = daysFromCivil(year, month, day);
    const secs = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
    return @intCast(@max(secs, 0));
}

const is_x86 = @import("builtin").cpu.arch == .x86_64;

/// Read the RTC, derive the epoch base, and arm the wall-clock offset.
/// No-op on non-x86 builds and when the RTC never leaves the
/// update-in-progress state (broken/absent hardware keeps the boot-time
/// clock rather than hanging the boot).
pub fn init() void {
    if (comptime !is_x86) return;
    const io = @import("../arch/x86_64/io.zig");
    const serial = @import("../arch/x86_64/serial.zig");
    const tsc = @import("../arch/x86_64/tsc.zig");
    const time_mod = @import("../proc/time_syscall.zig");
    const fmt = @import("../lib/fmt.zig");

    // Wait (bounded) for any RTC update cycle to finish: register A bit 7.
    var tries: u32 = 0;
    while (tries < 1_000_000) : (tries += 1) {
        io.outb(0x70, 0x0A);
        if (io.inb(0x71) & 0x80 == 0) break;
    } else {
        serial.writeString("[rtc] update-in-progress stuck, wall clock stays boot-relative\n");
        return;
    }

    const regB = readReg(io, 0x0B);
    const binary_mode = (regB & 0x04) != 0;
    const hour24 = (regB & 0x02) != 0;

    var second = readReg(io, 0x00);
    var minute = readReg(io, 0x02);
    var hour = readReg(io, 0x04);
    const day = readReg(io, 0x07);
    const month = readReg(io, 0x08);
    const year = readReg(io, 0x09);

    if (!binary_mode) {
        // BCD mode: the PM bit (0x80) of the hour register is a plain bit,
        // not a BCD nibble — strip it before conversion.
        const pm = (hour & 0x80) != 0;
        second = bcdToBin(second);
        minute = bcdToBin(minute);
        hour = bcdToBin(hour & 0x7F);
        if (!hour24 and pm and hour < 12) hour += 12;
        if (!hour24 and !pm and hour == 12) hour = 0;
        if (month > 12 or day > 31 or month == 0 or day == 0) {
            serial.writeString("[rtc] implausible BCD date, wall clock stays boot-relative\n");
            return;
        }
        const epoch = dateTimeToEpoch(expandYear(bcdToBin(year)), bcdToBin(month), bcdToBin(day), hour, minute, second);
        arm(epoch, serial, tsc, time_mod, fmt);
    } else {
        const pm = (hour & 0x80) != 0;
        hour &= 0x7F;
        if (!hour24 and pm and hour < 12) hour += 12;
        if (!hour24 and !pm and hour == 12) hour = 0;
        if (month > 12 or day > 31 or month == 0 or day == 0) {
            serial.writeString("[rtc] implausible date, wall clock stays boot-relative\n");
            return;
        }
        const epoch = dateTimeToEpoch(expandYear(year), month, day, hour, minute, second);
        arm(epoch, serial, tsc, time_mod, fmt);
    }
}

fn readReg(io: anytype, reg: u8) u8 {
    io.outb(0x70, reg);
    return io.inb(0x71);
}

fn arm(epoch_sec: u64, serial: anytype, tsc: anytype, time_mod: anytype, fmt: anytype) void {
    // wall_clock_offset = epoch_ns - boot_ns, same shape clock_settime uses.
    const epoch_ns: i64 = @intCast(epoch_sec * 1_000_000_000);
    const boot_ns: i64 = @intCast(tsc.nanos());
    time_mod.setWallClockOffset(epoch_ns - boot_ns);
    serial.writeString("[rtc] wall clock base epoch=");
    fmt.writeDecimal64(epoch_sec);
    serial.writeString("\n");
}
