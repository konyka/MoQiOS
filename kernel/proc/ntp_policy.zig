/// adjtimex / clock_adjtime(CLOCK_REALTIME): the kernel's NTP variables, without the kernel around them (time_syscall.zig owns
/// the instance). Linux kernel/time/ntp.c (ntp_adjtimex, process_adjtimex_modes, process_adj_status, is_error_status) and
/// timekeeping.c (timekeeping_validate_timex). The variables are kept and reported; the clock is not disciplined by them (no
/// PLL/FLL, no slewing of an adjtime offset, no leap-second insertion). What does act: the TAI offset (CLOCK_TAI is REALTIME plus
/// it) and ADJ_SETOFFSET (steps REALTIME).

pub const ADJ_OFFSET: u32 = 0x0001;
pub const ADJ_FREQUENCY: u32 = 0x0002;
pub const ADJ_MAXERROR: u32 = 0x0004;
pub const ADJ_ESTERROR: u32 = 0x0008;
pub const ADJ_STATUS: u32 = 0x0010;
pub const ADJ_TIMECONST: u32 = 0x0020;
pub const ADJ_TAI: u32 = 0x0080;
pub const ADJ_SETOFFSET: u32 = 0x0100;
pub const ADJ_MICRO: u32 = 0x1000;
pub const ADJ_NANO: u32 = 0x2000;
pub const ADJ_TICK: u32 = 0x4000;
pub const ADJ_ADJTIME: u32 = 0x8000;
pub const ADJ_OFFSET_SINGLESHOT: u32 = 0x0001;
pub const ADJ_OFFSET_READONLY: u32 = 0x2000;

pub const STA_PLL: i32 = 0x0001;
pub const STA_PPSFREQ: i32 = 0x0002;
pub const STA_PPSTIME: i32 = 0x0004;
pub const STA_UNSYNC: i32 = 0x0040;
pub const STA_PPSSIGNAL: i32 = 0x0100;
pub const STA_PPSJITTER: i32 = 0x0200;
pub const STA_PPSWANDER: i32 = 0x0400;
pub const STA_PPSERROR: i32 = 0x0800;
pub const STA_CLOCKERR: i32 = 0x1000;
pub const STA_NANO: i32 = 0x2000;
pub const STA_RONLY: i32 = 0xff00;

pub const TIME_OK: i64 = 0;
pub const TIME_ERROR: i64 = 5;

const EPERM: i64 = -1;
const EINVAL: i64 = -22;

const NSEC_PER_USEC: i64 = 1000;
const USEC_PER_SEC: i64 = 1_000_000;
const NSEC_PER_SEC: i64 = 1_000_000_000;
const USER_HZ: i64 = 100;
const NTP_SCALE_SHIFT = 32;
const SHIFT_USEC = 16;
const PPM_SCALE: i64 = NSEC_PER_USEC << (NTP_SCALE_SHIFT - SHIFT_USEC);
const PPM_SCALE_INV_SHIFT = 19;
const PPM_SCALE_INV: i64 = @divTrunc(@as(i64, 1) << (PPM_SCALE_INV_SHIFT + NTP_SCALE_SHIFT), PPM_SCALE);
const MAXPHASE: i64 = 500_000_000;
const MAXFREQ: i64 = 500_000;
const MAXFREQ_SCALED: i64 = MAXFREQ << NTP_SCALE_SHIFT;
pub const NTP_PHASE_LIMIT: i64 = @divTrunc(MAXPHASE, NSEC_PER_USEC) << 5;
const MAXTC: i64 = 10;
pub const MAX_TAI_OFFSET: i32 = 100_000;
pub const USER_TICK_USEC: i64 = @divTrunc(1_000_000 + @divTrunc(USER_HZ, 2), USER_HZ);
pub const TOLERANCE: i64 = @divTrunc(MAXFREQ_SCALED, PPM_SCALE);

/// struct timex (x86_64, 208 bytes): the fields adjtimex reads and writes.
pub const TIMEX_SIZE: usize = 208;
pub const Timex = struct {
    modes: u32 = 0,
    offset: i64 = 0,
    freq: i64 = 0,
    maxerror: i64 = 0,
    esterror: i64 = 0,
    status: i32 = 0,
    constant: i64 = 0,
    precision: i64 = 0,
    tolerance: i64 = 0,
    time_sec: i64 = 0,
    time_usec: i64 = 0,
    tick: i64 = 0,
    tai: i32 = 0,
};

pub const State = struct {
    status: i32 = STA_UNSYNC,
    time_state: i64 = TIME_OK,
    /// Scaled as Linux's time_freq (ns/s << 32).
    freq: i64 = 0,
    maxerror: i64 = NTP_PHASE_LIMIT,
    esterror: i64 = NTP_PHASE_LIMIT,
    constant: i64 = 2,
    tick: i64 = USER_TICK_USEC,
    /// adjtime()'s pending offset, in microseconds (kept, not slewed).
    adjust: i64 = 0,
    tai: i32 = 0,
};

/// timekeeping_validate_timex: 0, or the errno that refuses the request before anything changes.
pub fn validate(tx: *const Timex, cap_sys_time: bool) i64 {
    if (tx.modes & ADJ_ADJTIME != 0) {
        if (tx.modes & ADJ_OFFSET_SINGLESHOT == 0) return EINVAL;
        if (tx.modes & ADJ_OFFSET_READONLY == 0 and !cap_sys_time) return EPERM;
    } else {
        if (tx.modes != 0 and !cap_sys_time) return EPERM;
        if (tx.modes & ADJ_TICK != 0 and (tx.tick < @divTrunc(900_000, USER_HZ) or tx.tick > @divTrunc(1_100_000, USER_HZ))) return EINVAL;
    }
    if (tx.modes & ADJ_SETOFFSET != 0) {
        if (!cap_sys_time) return EPERM;
        if (tx.time_usec < 0) return EINVAL;
        if (tx.time_usec >= (if (tx.modes & ADJ_NANO != 0) NSEC_PER_SEC else USEC_PER_SEC)) return EINVAL;
    }
    if (tx.modes & ADJ_FREQUENCY != 0) {
        if (@divTrunc(std.math.minInt(i64), PPM_SCALE) > tx.freq) return EINVAL;
        if (@divTrunc(std.math.maxInt(i64), PPM_SCALE) < tx.freq) return EINVAL;
    }
    return 0;
}

/// The step ADJ_SETOFFSET asks for, in nanoseconds (call after validate).
pub fn setOffsetNs(tx: *const Timex) i64 {
    const sub = if (tx.modes & ADJ_NANO != 0) tx.time_usec else tx.time_usec * NSEC_PER_USEC;
    return tx.time_sec *| NSEC_PER_SEC +| sub;
}

fn isErrorStatus(status: i32) bool {
    return (status & (STA_UNSYNC | STA_CLOCKERR)) != 0 or
        ((status & (STA_PPSFREQ | STA_PPSTIME)) != 0 and (status & STA_PPSSIGNAL) == 0) or
        ((status & (STA_PPSTIME | STA_PPSJITTER)) == (STA_PPSTIME | STA_PPSJITTER)) or
        ((status & STA_PPSFREQ) != 0 and (status & (STA_PPSWANDER | STA_PPSERROR)) != 0);
}

/// ntp_adjtimex: apply a validated request to `s` and fill `tx` with the result; `now_*` is CLOCK_REALTIME after any step.
/// Returns the clock state (TIME_OK, or TIME_ERROR while the status says unsynchronised).
pub fn adjtimex(s: *State, tx: *Timex, now_sec: i64, now_nsec: i64) i64 {
    if (tx.modes & ADJ_ADJTIME != 0) {
        const save = s.adjust;
        if (tx.modes & ADJ_OFFSET_READONLY == 0) s.adjust = tx.offset;
        tx.offset = save;
    } else {
        if (tx.modes != 0) applyModes(s, tx);
        tx.offset = 0; // no PLL phase offset is ever accumulated
    }
    const result = if (isErrorStatus(s.status)) TIME_ERROR else s.time_state;
    tx.freq = ((s.freq >> PPM_SCALE_INV_SHIFT) *% PPM_SCALE_INV) >> NTP_SCALE_SHIFT;
    tx.maxerror = s.maxerror;
    tx.esterror = s.esterror;
    tx.status = s.status;
    tx.constant = s.constant;
    tx.precision = 1;
    tx.tolerance = TOLERANCE;
    tx.tick = s.tick;
    tx.tai = s.tai;
    tx.time_sec = now_sec;
    tx.time_usec = if (s.status & STA_NANO != 0) now_nsec else @divTrunc(now_nsec, NSEC_PER_USEC);
    return result;
}

fn applyModes(s: *State, tx: *const Timex) void {
    if (tx.modes & ADJ_STATUS != 0) {
        if ((s.status & STA_PLL) != 0 and (tx.status & STA_PLL) == 0) {
            s.time_state = TIME_OK;
            s.status = STA_UNSYNC;
        }
        s.status &= STA_RONLY;
        s.status |= tx.status & ~STA_RONLY;
    }
    if (tx.modes & ADJ_NANO != 0) s.status |= STA_NANO;
    if (tx.modes & ADJ_MICRO != 0) s.status &= ~STA_NANO;
    if (tx.modes & ADJ_FREQUENCY != 0) s.freq = std.math.clamp(tx.freq *| PPM_SCALE, -MAXFREQ_SCALED, MAXFREQ_SCALED);
    if (tx.modes & ADJ_MAXERROR != 0) s.maxerror = std.math.clamp(tx.maxerror, 0, NTP_PHASE_LIMIT);
    if (tx.modes & ADJ_ESTERROR != 0) s.esterror = std.math.clamp(tx.esterror, 0, NTP_PHASE_LIMIT);
    if (tx.modes & ADJ_TIMECONST != 0) {
        var c = std.math.clamp(tx.constant, 0, MAXTC);
        if (s.status & STA_NANO == 0) c += 4;
        s.constant = std.math.clamp(c, 0, MAXTC);
    }
    if (tx.modes & ADJ_TAI != 0 and tx.constant >= 0 and tx.constant <= MAX_TAI_OFFSET) s.tai = @intCast(tx.constant);
    if (tx.modes & ADJ_TICK != 0) s.tick = tx.tick;
}

/// clock_adjtime(clockid, ...) for a clock other than CLOCK_REALTIME (Linux measured): the other clocks have no clock_adj
/// (EOPNOTSUPP), ids that name no clock are EINVAL, and the auxiliary clocks 16..23 are ENODEV while not enabled.
pub fn otherClockErrno(clockid: i64) i64 {
    const clk: i32 = @bitCast(@as(u32, @truncate(@as(u64, @bitCast(clockid)))));
    if (clk < 0) return if ((clk & 7) == 3) EINVAL else -95;
    return switch (clk) {
        1...9, 11 => -95,
        16...23 => -19,
        else => EINVAL,
    };
}

pub fn decode(buf: *const [TIMEX_SIZE]u8) Timex {
    return .{
        .modes = rd(u32, buf, 0),
        .offset = rd(i64, buf, 8),
        .freq = rd(i64, buf, 16),
        .maxerror = rd(i64, buf, 24),
        .esterror = rd(i64, buf, 32),
        .status = rd(i32, buf, 40),
        .constant = rd(i64, buf, 48),
        .precision = rd(i64, buf, 56),
        .tolerance = rd(i64, buf, 64),
        .time_sec = rd(i64, buf, 72),
        .time_usec = rd(i64, buf, 80),
        .tick = rd(i64, buf, 88),
        .tai = rd(i32, buf, 160),
    };
}

/// Write the result fields back over the caller's struct (modes and the PPS fields are left as they were; the PPS ones are 0
/// in a fresh struct and this kernel has no PPS source).
pub fn encode(tx: *const Timex, buf: *[TIMEX_SIZE]u8) void {
    wr(i64, buf, 8, tx.offset);
    wr(i64, buf, 16, tx.freq);
    wr(i64, buf, 24, tx.maxerror);
    wr(i64, buf, 32, tx.esterror);
    wr(i32, buf, 40, tx.status);
    wr(i64, buf, 48, tx.constant);
    wr(i64, buf, 56, tx.precision);
    wr(i64, buf, 64, tx.tolerance);
    wr(i64, buf, 72, tx.time_sec);
    wr(i64, buf, 80, tx.time_usec);
    wr(i64, buf, 88, tx.tick);
    @memset(buf[96..160], 0);
    wr(i32, buf, 160, tx.tai);
}

fn rd(comptime T: type, buf: *const [TIMEX_SIZE]u8, off: usize) T {
    return std.mem.readInt(T, buf[off..][0..@sizeOf(T)], .little);
}

fn wr(comptime T: type, buf: *[TIMEX_SIZE]u8, off: usize, v: T) void {
    std.mem.writeInt(T, buf[off..][0..@sizeOf(T)], v, .little);
}

const std = @import("std");
