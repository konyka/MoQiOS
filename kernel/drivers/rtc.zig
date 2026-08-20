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

pub fn validBcd(bcd: u8) bool {
    return (bcd >> 4) <= 9 and (bcd & 0x0F) <= 9;
}

pub fn isLeapYear(y: u16) bool {
    return (y % 4 == 0 and y % 100 != 0) or y % 400 == 0;
}

pub fn validDate(year: u16, month: u8, day: u8) bool {
    if (month == 0 or month > 12 or day == 0) return false;
    const days: u8 = switch (month) {
        2 => if (isLeapYear(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    return day <= days;
}

pub fn validClockTime(hour: u8, minute: u8, second: u8, hour24: bool) bool {
    if (minute > 59 or second > 59) return false;
    if (hour24) return hour <= 23;
    return hour >= 1 and hour <= 12;
}

pub fn normalizeRtcHour(hour: u8, pm: bool, hour24: bool) ?u8 {
    if (hour24) return if (hour <= 23) hour else null;
    if (hour == 0 or hour > 12) return null;
    if (pm and hour < 12) return hour + 12;
    if (!pm and hour == 12) return 0;
    return hour;
}

pub fn decodeRtcHour(raw: u8, binary_mode: bool, hour24: bool) ?u8 {
    const pm = (raw & 0x80) != 0;
    if (hour24 and pm) return null;
    const hour = if (binary_mode) raw & 0x7F else bcdToBin(raw & 0x7F);
    return normalizeRtcHour(hour, pm, hour24);
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

    // CMOS can expose a torn snapshot around an update boundary. Retry a
    // bounded number of complete snapshots before falling back to boot time.
    var budget: u64 = 10_000_000;
    snapshot: while (budget > 0) {
        var tries: u32 = 0;
        var uip_clear = false;
        while (tries < 100_000 and budget > 0) : (tries += 1) {
            const reg_a = readRegBudgeted(io, 0x0A, &budget) orelse break;
            if (reg_a & 0x80 == 0) {
                uip_clear = true;
                break;
            }
        }
        if (budget == 0 or !uip_clear) continue :snapshot;

    const regB = readRegBudgeted(io, 0x0B, &budget) orelse break;
    const binary_mode = (regB & 0x04) != 0;
    const hour24 = (regB & 0x02) != 0;

    const second_raw = readRegBudgeted(io, 0x00, &budget) orelse break;
    var minute = readRegBudgeted(io, 0x02, &budget) orelse break;
    const hour = readRegBudgeted(io, 0x04, &budget) orelse break;
    const day = readRegBudgeted(io, 0x07, &budget) orelse break;
    const month = readRegBudgeted(io, 0x08, &budget) orelse break;
    const year = readRegBudgeted(io, 0x09, &budget) orelse break;
    const reg_a_after = readRegBudgeted(io, 0x0A, &budget) orelse break;
    if (reg_a_after & 0x80 != 0) continue :snapshot;
    const second_confirm = readRegBudgeted(io, 0x00, &budget) orelse break;
    if (second_confirm != second_raw) continue :snapshot;
    var second = second_raw;

    if (!binary_mode) {
        // BCD mode: the PM bit (0x80) of the hour register is a plain bit,
        // not a BCD nibble — strip it before conversion.
        if (!validBcd(second) or !validBcd(minute) or !validBcd(hour & 0x7F) or
            !validBcd(day) or !validBcd(month) or !validBcd(year)) continue :snapshot;
        const calendar_year = expandYear(bcdToBin(year));
        const calendar_month = bcdToBin(month);
        const calendar_day = bcdToBin(day);
        second = bcdToBin(second);
        minute = bcdToBin(minute);
        const normalized_hour = decodeRtcHour(hour, false, hour24) orelse continue :snapshot;
        if (!validDate(calendar_year, calendar_month, calendar_day) or
            !validClockTime(normalized_hour, minute, second, true)) {
            continue :snapshot;
        }
        const epoch = dateTimeToEpoch(calendar_year, calendar_month, calendar_day, normalized_hour, minute, second);
        arm(epoch, serial, tsc, time_mod, fmt);
        return;
    } else {
        if (year > 99) continue :snapshot;
        const normalized_hour = decodeRtcHour(hour, true, hour24) orelse continue :snapshot;
        if (!validDate(expandYear(year), month, day) or
            !validClockTime(normalized_hour, minute, second, true)) {
            continue :snapshot;
        }
        const epoch = dateTimeToEpoch(expandYear(year), month, day, normalized_hour, minute, second);
        arm(epoch, serial, tsc, time_mod, fmt);
        return;
    }
    }
    serial.writeString("[rtc] no stable CMOS snapshot, wall clock stays boot-relative\n");
}

fn readReg(io: anytype, reg: u8) u8 {
    io.outb(0x70, reg);
    return io.inb(0x71);
}

fn readRegBudgeted(io: anytype, reg: u8, budget: *u64) ?u8 {
    if (budget.* == 0) return null;
    budget.* -= 1;
    return readReg(io, reg);
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
