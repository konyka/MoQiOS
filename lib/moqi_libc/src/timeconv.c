/* timeconv.c — calendar conversion and strftime (see include/time.h). The local zone is UTC. */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "../include/errno.h"
#include "../include/time.h"

#define SECS_PER_DAY 86400LL

/* Days since 1970-01-01 of the civil date y-m-d (m in 1..12). Howard Hinnant's algorithm; exact for the whole int64
 * range that fits, with floor semantics for dates before the epoch. */
static int64_t days_from_civil(int64_t y, int m, int d) {
    y -= m <= 2;
    int64_t era = (y >= 0 ? y : y - 399) / 400;
    int64_t yoe = y - era * 400;
    int64_t doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    int64_t doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

static void civil_from_days(int64_t z, int64_t *y, int *m, int *d) {
    z += 719468;
    int64_t era = (z >= 0 ? z : z - 146096) / 146097;
    int64_t doe = z - era * 146097;
    int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    int64_t yy = yoe + era * 400;
    int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    int64_t mp = (5 * doy + 2) / 153;
    *d = (int)(doy - (153 * mp + 2) / 5 + 1);
    *m = (int)(mp < 10 ? mp + 3 : mp - 9);
    *y = yy + (*m <= 2);
}

static int64_t floor_div(int64_t a, int64_t b) {
    int64_t q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

static int64_t floor_mod(int64_t a, int64_t b) {
    return a - floor_div(a, b) * b;
}

/* Fills every field but the zone ones. False when the year does not fit an int. */
static int break_down(int64_t t, struct tm *out, const char *zone) {
    int64_t days = floor_div(t, SECS_PER_DAY);
    int64_t rem = t - days * SECS_PER_DAY;
    int64_t y;
    int m, d;
    civil_from_days(days, &y, &m, &d);
    if (y - 1900 > 2147483647LL || y - 1900 < -2147483648LL) return 0;
    out->tm_year = (int)(y - 1900);
    out->tm_mon = m - 1;
    out->tm_mday = d;
    out->tm_hour = (int)(rem / 3600);
    out->tm_min = (int)(rem % 3600 / 60);
    out->tm_sec = (int)(rem % 60);
    out->tm_wday = (int)floor_mod(days + 4, 7); /* 1970-01-01 was a Thursday */
    out->tm_yday = (int)(days - days_from_civil(y, 1, 1));
    out->tm_isdst = 0;
    out->tm_gmtoff = 0;
    out->tm_zone = zone;
    return 1;
}

struct tm *gmtime_r(const time_t *t, struct tm *out) {
    if (!break_down((int64_t)*t, out, "GMT")) {
        errno = EOVERFLOW;
        return (struct tm *)0;
    }
    return out;
}

static struct tm static_tm;

struct tm *gmtime(const time_t *t) {
    return gmtime_r(t, &static_tm);
}

struct tm *localtime_r(const time_t *t, struct tm *out) {
    if (!break_down((int64_t)*t, out, "UTC")) {
        errno = EOVERFLOW;
        return (struct tm *)0;
    }
    return out;
}

struct tm *localtime(const time_t *t) {
    return localtime_r(t, &static_tm);
}

/* tm -> seconds with every field normalised, using floor division so negative fields carry correctly. The month is
 * folded into the year first; any intermediate that does not fit 64 bits is an overflow. */
/* Date, hours and minutes, as seconds. This partial total has to be representable on its own: glibc settles it before
 * the seconds are added (and before the daylight saving hour is taken off), so an out-of-range intermediate fails even
 * when the seconds would bring the final answer back in range (measured near both ends of tm_year). */
static int to_seconds_hm(const struct tm *tm, int64_t *out) {
    int64_t year = (int64_t)tm->tm_year + 1900;
    int64_t mon = tm->tm_mon;
    year += floor_div(mon, 12);
    mon = floor_mod(mon, 12);
    int64_t days = days_from_civil(year, (int)mon + 1, 1);
    int64_t total_days = days + ((int64_t)tm->tm_mday - 1);
    int64_t result;
    if (__builtin_mul_overflow(total_days, SECS_PER_DAY, &result)) return 0;
    int64_t hm = (int64_t)tm->tm_hour * 3600 + (int64_t)tm->tm_min * 60;
    if (__builtin_add_overflow(result, hm, &result)) return 0;
    struct tm probe;
    if (!break_down(result, &probe, "GMT")) return 0;
    *out = result;
    return 1;
}

static int to_seconds(const struct tm *tm, int64_t *out) {
    int64_t result;
    if (!to_seconds_hm(tm, &result)) return 0;
    if (__builtin_add_overflow(result, (int64_t)tm->tm_sec, &result)) return 0;
    *out = result;
    return 1;
}

time_t timegm(struct tm *tm) {
    int64_t secs;
    struct tm normalised;
    if (!to_seconds(tm, &secs) || !break_down(secs, &normalised, "GMT")) {
        /* glibc clears tm_isdst and touches nothing else when the result does not fit. */
        tm->tm_isdst = 0;
        errno = EOVERFLOW;
        return (time_t)-1;
    }
    *tm = normalised;
    return (time_t)secs;
}

/* mktime's arithmetic: in this zone tm_isdst > 0 is taken as daylight saving time, an hour ahead of standard time
 * (glibc does the same even though the zone has no DST), so the instant is an hour earlier. */
static int to_epoch(const struct tm *tm, int64_t *out) {
    int64_t secs;
    struct tm probe;
    if (!to_seconds_hm(tm, &secs)) return 0;
    /* With tm_isdst > 0 the hour comes off the date+hour+minute total, which must still be representable; the seconds
     * are added afterwards and only the final result is range-checked (measured at both ends of tm_year). */
    if (tm->tm_isdst > 0) {
        if (__builtin_sub_overflow(secs, 3600LL, &secs)) return 0;
        if (!break_down(secs, &probe, "UTC")) return 0;
    }
    if (__builtin_add_overflow(secs, (int64_t)tm->tm_sec, &secs)) return 0;
    if (!break_down(secs, &probe, "UTC")) return 0;
    *out = secs;
    return 1;
}

time_t mktime(struct tm *tm) {
    int64_t secs;
    struct tm normalised;
    if (!to_epoch(tm, &secs) || !break_down(secs, &normalised, "UTC")) {
        /* Unlike timegm, mktime leaves *tm exactly as it was (measured). */
        errno = EOVERFLOW;
        return (time_t)-1;
    }
    *tm = normalised;
    return (time_t)secs;
}

double difftime(time_t end, time_t begin) {
    return (double)end - (double)begin;
}

/* ---- strftime ---------------------------------------------------------------------------------------------------- */

/* Output cursor. Every write must leave room for the terminating NUL, otherwise the whole call fails with 0 (as in
 * glibc). */
struct sink {
    char *p;
    size_t i;
    size_t max;
};

static int room(const struct sink *o, size_t n) {
    return n < o->max - o->i;
}

static int put(struct sink *o, const char *s, size_t n) {
    if (!room(o, n)) return 0;
    memcpy(o->p + o->i, s, n);
    o->i += n;
    return 1;
}

static int put_fill(struct sink *o, size_t n, char c) {
    if (!room(o, n)) return 0;
    memset(o->p + o->i, c, n);
    o->i += n;
    return 1;
}

static char up(char c) { return (c >= 'a' && c <= 'z') ? (char)(c - 'a' + 'A') : c; }
static char low(char c) { return (c >= 'A' && c <= 'Z') ? (char)(c - 'A' + 'a') : c; }

/* Flags and width of one conversion. pad is 0 (default), '_' (spaces), '-' (none) or '0'. */
struct spec {
    char pad;
    int upper;  /* '^' */
    int swap;   /* '#' */
    size_t width;
    int has_width;
};

/* Text, padded on the left to the width (with zeros only for the '0' flag), case forced as asked. */
static int put_text(struct sink *o, const char *s, size_t n, const struct spec *sp, int force_upper, int force_lower) {
    if (sp->has_width && sp->width > n && !put_fill(o, sp->width - n, sp->pad == '0' ? '0' : ' ')) return 0;
    if (!room(o, n)) return 0;
    for (size_t k = 0; k < n; k++) o->p[o->i + k] = force_lower ? low(s[k]) : (force_upper ? up(s[k]) : s[k]);
    o->i += n;
    return 1;
}

/* A number with at least `digits` digits (zero or space filled by default, per `dflt`). The '-' flag drops the digit
 * padding, but an explicit width still pads with spaces. A '_' or '0' flag overrides `dflt`. */
static int put_number(struct sink *o, long long value, size_t digits, char dflt, const struct spec *sp) {
    char buf[24];
    int neg = value < 0;
    unsigned long long mag = neg ? 0ULL - (unsigned long long)value : (unsigned long long)value;
    size_t len = 0;
    do { buf[len++] = (char)('0' + mag % 10); mag /= 10; } while (mag != 0);
    char pad = sp->pad ? sp->pad : dflt;
    size_t text = len + (neg ? 1u : 0u);
    size_t target = digits;
    if (sp->has_width && sp->width > target) target = sp->width;
    if (pad == '-') target = sp->has_width ? sp->width : 0;
    size_t fill = target > text ? target - text : 0;
    if (pad == '0') {
        if (neg && !put(o, "-", 1)) return 0;
        if (!put_fill(o, fill, '0')) return 0;
    } else {
        if (!put_fill(o, fill, ' ')) return 0;
        if (neg && !put(o, "-", 1)) return 0;
    }
    if (!room(o, len)) return 0;
    for (size_t k = 0; k < len; k++) o->p[o->i + k] = buf[len - 1 - k];
    o->i += len;
    return 1;
}

static const char *const day_long[7] = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"};
static const char *const month_long[12] = {"January", "February", "March", "April", "May", "June", "July", "August",
                                           "September", "October", "November", "December"};

/* tm_year + 1900 wraps in a 32-bit int in glibc's strftime (a tm_year of INT_MAX prints as -2147481749); so does every
 * year derived from it. Unsigned arithmetic gives the same wrap without undefined behaviour. */
static int wrap_add(int a, int b) { return (int)((unsigned)a + (unsigned)b); }
static int wrap_sub(int a, int b) { return (int)((unsigned)a - (unsigned)b); }

static int cal_year(const struct tm *tm) { return wrap_add(tm->tm_year, 1900); }

static int leap_year(int y) {
    return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0);
}

/* glibc's iso_week_days(): the day of the week-based year the week structure is anchored on. Its answers for
 * out-of-range wday/yday were compared against the real strftime over a 6.7 million point grid. */
static int iso_week_days(int yday, int wday) {
    const int big_enough_multiple_of_7 = (366 / 7 + 2) * 7;
    return yday - (yday - wday + 4 + big_enough_multiple_of_7) % 7 + 3;
}

static void iso_week(const struct tm *tm, int *year, int *week) {
    int y = cal_year(tm);
    int days = iso_week_days(tm->tm_yday, tm->tm_wday);
    if (days < 0) {
        y = wrap_sub(y, 1);
        days = iso_week_days(tm->tm_yday + (365 + leap_year(y)), tm->tm_wday);
    } else {
        int d = iso_week_days(tm->tm_yday - (365 + leap_year(y)), tm->tm_wday);
        if (d >= 0) {
            y = wrap_add(y, 1);
            days = d;
        }
    }
    *year = y;
    *week = days / 7 + 1;
}

static int floor_div_int(int a, int b) {
    int q = a / b;
    return (a % b != 0 && ((a < 0) != (b < 0))) ? q - 1 : q;
}

static int format(struct sink *o, const char *f, const struct tm *tm);

/* One composite conversion: format it, then case-force / pad the produced text like a string conversion. glibc ignores
 * the flags and the width for the composites that are built from numbers (%c %x %X %r %R %D %F %T), except that a
 * width larger than the text left-pads (with spaces, or zeros for the 0 flag). */
static int put_composite(struct sink *o, const char *sub, const struct tm *tm, const struct spec *sp, int force_upper) {
    char tmp[64];
    struct sink t = { tmp, 0, sizeof tmp };
    if (!format(&t, sub, tm)) return 0;
    return put_text(o, tmp, t.i, sp, force_upper, 0);
}

static int convert(struct sink *o, char c, const struct spec *sp, const struct tm *tm, int alt) {
    (void)alt;
    switch (c) {
    case '%': {
        char pc = '%';
        return put_text(o, &pc, 1, sp, 0, 0);
    }
    case 'n': {
        char nl = '\n';
        return put_text(o, &nl, 1, sp, 0, 0);
    }
    case 't': {
        char tb = '\t';
        return put_text(o, &tb, 1, sp, 0, 0);
    }
    case 'a':
    case 'A': {
        int ok = tm->tm_wday >= 0 && tm->tm_wday <= 6;
        const char *name = ok ? day_long[tm->tm_wday] : "?";
        size_t n = ok ? (c == 'a' ? 3 : strlen(name)) : 1;
        return put_text(o, name, n, sp, sp->upper || sp->swap, 0);
    }
    case 'b':
    case 'B':
    case 'h': {
        int ok = tm->tm_mon >= 0 && tm->tm_mon <= 11;
        const char *name = ok ? month_long[tm->tm_mon] : "?";
        size_t n = ok ? (c == 'B' ? strlen(name) : 3) : 1;
        return put_text(o, name, n, sp, sp->upper || sp->swap, 0);
    }
    case 'p':
    case 'P': {
        const char *ampm = tm->tm_hour > 11 ? "PM" : "AM";
        int lower = c == 'P' || sp->swap;
        return put_text(o, ampm, 2, sp, 0, lower);
    }
    case 'c': return put_composite(o, "%a %b %e %H:%M:%S %Y", tm, sp, sp->upper);
    case 'x':
    case 'D': return put_composite(o, "%m/%d/%y", tm, sp, 0);
    case 'X':
    case 'T': return put_composite(o, "%H:%M:%S", tm, sp, 0);
    case 'r': return put_composite(o, "%I:%M:%S %p", tm, sp, 0);
    case 'R': return put_composite(o, "%H:%M", tm, sp, 0);
    case 'F': return put_composite(o, "%Y-%m-%d", tm, sp, 0);
    case 'C': return put_number(o, floor_div_int(cal_year(tm), 100), 1, '0', sp);
    case 'd': return put_number(o, tm->tm_mday, 2, '0', sp);
    case 'e': return put_number(o, tm->tm_mday, 2, '_', sp);
    case 'H': return put_number(o, tm->tm_hour, 2, '0', sp);
    case 'k': return put_number(o, tm->tm_hour, 2, '_', sp);
    case 'I':
    case 'l': {
        /* glibc: above 12 subtract 12, 0 is 12, everything else (negative hours included) is printed as it is. */
        int hour12 = tm->tm_hour;
        if (hour12 > 12) hour12 -= 12;
        else if (hour12 == 0) hour12 = 12;
        return put_number(o, hour12, 2, c == 'I' ? '0' : '_', sp);
    }
    case 'j': return put_number(o, (long long)tm->tm_yday + 1, 3, '0', sp);
    case 'm': return put_number(o, (long long)tm->tm_mon + 1, 2, '0', sp);
    case 'M': return put_number(o, tm->tm_min, 2, '0', sp);
    case 'S': return put_number(o, tm->tm_sec, 2, '0', sp);
    case 'u': return put_number(o, ((tm->tm_wday + 6) % 7 + 7) % 7 + 1, 1, '0', sp);
    case 'w': return put_number(o, tm->tm_wday, 1, '0', sp);
    case 'U': return put_number(o, (tm->tm_yday - tm->tm_wday + 7) / 7, 2, '0', sp);
    case 'W': return put_number(o, (tm->tm_yday - (tm->tm_wday - 1 + 7) % 7 + 7) / 7, 2, '0', sp);
    case 'V': {
        int y, w;
        iso_week(tm, &y, &w);
        return put_number(o, w, 2, '0', sp);
    }
    case 'G': {
        int y, w;
        iso_week(tm, &y, &w);
        return put_number(o, y, 1, '0', sp);
    }
    case 'g': {
        int y, w;
        iso_week(tm, &y, &w);
        return put_number(o, ((y % 100) + 100) % 100, 2, '0', sp);
    }
    case 'y': return put_number(o, ((tm->tm_year % 100) + 100) % 100, 2, '0', sp);
    case 'Y': return put_number(o, cal_year(tm), 1, '0', sp);
    case 's': {
        /* A string, not a number: the width pads in front of the whole text, sign included, with zeros only for the
         * 0 flag (so "%013s" of a negative time is "000-503971200"). An out-of-range time prints -1. */
        int64_t secs;
        if (!to_epoch(tm, &secs)) secs = -1;
        char buf[24];
        int neg = secs < 0;
        unsigned long long mag = neg ? 0ULL - (unsigned long long)secs : (unsigned long long)secs;
        size_t len = 0;
        do { buf[len++] = (char)('0' + mag % 10); mag /= 10; } while (mag != 0);
        if (neg) buf[len++] = '-';
        char text[24];
        for (size_t k = 0; k < len; k++) text[k] = buf[len - 1 - k];
        return put_text(o, text, len, sp, 0, 0);
    }
    case 'z': {
        if (tm->tm_isdst < 0) return 1;
        long off = tm->tm_gmtoff;
        int neg = off < 0;
        unsigned long long mag = neg ? 0ULL - (unsigned long long)off : (unsigned long long)off;
        unsigned long long hhmm = (mag / 3600) * 100 + (mag % 3600) / 60;
        /* glibc's layout (measured): the width pads in front of the sign (w-1 characters: spaces, or zeros for the 0
         * flag), the sign follows, then the hhmm number with max(4, w) digits (zeros by default, spaces for '_'); the
         * '-' flag drops the zeros and uses w digits (none without a width). */
        size_t w = sp->has_width ? sp->width : 0;
        char pad = sp->pad ? sp->pad : '0';
        size_t digit_cols = pad == '-' ? w : (w > 4 ? w : 4);
        char buf[24];
        size_t len = 0;
        do { buf[len++] = (char)('0' + hhmm % 10); hhmm /= 10; } while (hhmm != 0);
        if (w > 1 && !put_fill(o, w - 1, sp->pad == '0' ? '0' : ' ')) return 0;
        if (!put(o, neg ? "-" : "+", 1)) return 0;
        if (digit_cols > len && !put_fill(o, digit_cols - len, pad == '0' ? '0' : ' ')) return 0;
        if (!room(o, len)) return 0;
        for (size_t k = 0; k < len; k++) o->p[o->i + k] = buf[len - 1 - k];
        o->i += len;
        return 1;
    }
    case 'Z': {
        const char *zone = tm->tm_zone;
        if (!zone || !zone[0]) {
            if (tm->tm_isdst < 0) return put_text(o, "", 0, sp, 0, 0);
            zone = tm->tm_isdst > 1 ? "?" : "UTC";
        }
        size_t n = strlen(zone);
        return put_text(o, zone, n, sp, sp->upper, sp->swap);
    }
    default:
        return -1;
    }
}

/* The E and O modifiers: which conversions each accepts, measured against glibc in the C locale. Both then behave like
 * the plain conversion. */
static int modifier_accepts(char mod, char c) {
    static const char e_set[] = "CPRTXYZcnprstuxyz%";
    static const char o_set[] = "BCGHIMPRSTUVWZbdeghjklmnprstuwyz%";
    const char *set = mod == 'E' ? e_set : o_set;
    for (; *set; set++) if (*set == c) return 1;
    return 0;
}

static int format(struct sink *o, const char *f, const struct tm *tm) {
    while (*f) {
        if (*f != '%') {
            if (!put(o, f, 1)) return 0;
            f++;
            continue;
        }
        const char *start = f;
        f++;
        struct spec sp = { 0, 0, 0, 0, 0 };
        for (;; f++) {
            if (*f == '_' || *f == '-' || *f == '0') sp.pad = *f;
            else if (*f == '^') sp.upper = 1;
            else if (*f == '#') sp.swap = 1;
            else break;
        }
        if (*f >= '0' && *f <= '9') {
            size_t w = 0;
            while (*f >= '0' && *f <= '9') {
                if (w > 100000000u) w = 100000000u;
                w = w * 10 + (size_t)(*f - '0');
                f++;
            }
            sp.width = w;
            sp.has_width = 1;
        }
        char mod = 0;
        if (*f == 'E' || *f == 'O') {
            mod = *f;
            f++;
        }
        char c = *f;
        if (c == '\0') {
            /* A lone '%' at the end: copied as written, under the width. */
            size_t n = (size_t)(f - start);
            if (sp.has_width && sp.width > n && !put_fill(o, sp.width - n, sp.pad == '0' ? '0' : ' ')) return 0;
            if (!put(o, start, n)) return 0;
            return 1;
        }
        int rc = (mod && !modifier_accepts(mod, c)) ? -1 : convert(o, c, &sp, tm, 0);
        if (rc == 0) return 0;
        if (rc < 0) {
            /* Unknown or invalid: the text is copied through, left-padded with spaces to the width (0 flag: zeros). */
            size_t n = (size_t)(f - start) + 1;
            if (c == '%' && !mod) n = 2;
            if (sp.has_width && sp.width > n && !put_fill(o, sp.width - n, sp.pad == '0' ? '0' : ' ')) return 0;
            /* glibc upper-cases the whole echoed sequence under '^', and under '#' for b and h with an E modifier. */
            int shout = sp.upper || (sp.swap && mod == 'E' && (c == 'b' || c == 'h'));
            if (!room(o, n)) return 0;
            for (size_t k = 0; k < n; k++) o->p[o->i + k] = shout ? up(start[k]) : start[k];
            o->i += n;
        }
        f++;
    }
    return 1;
}

size_t strftime(char *buf, size_t max, const char *fmt, const struct tm *tm) {
    if (max == 0) return 0;
    struct sink o = { buf, 0, max };
    if (!format(&o, fmt, tm)) return 0;
    buf[o.i] = '\0';
    return o.i;
}
