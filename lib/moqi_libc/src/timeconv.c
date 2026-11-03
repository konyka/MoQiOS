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

/* Fills `out` in glibc's order: zone fields, then hour/minute/second, weekday, and the year (truncated to an int) are
 * written before the year is checked, so on EOVERFLOW those are already set and yday/mon/mday are not (this shows in
 * what a failed strptime("%s") leaves behind). False when the year does not fit an int. */
static int break_down(int64_t t, struct tm *out, const char *zone) {
    out->tm_isdst = 0;
    out->tm_gmtoff = 0;
    out->tm_zone = zone;
    int64_t days = floor_div(t, SECS_PER_DAY);
    int64_t rem = t - days * SECS_PER_DAY;
    out->tm_hour = (int)(rem / 3600);
    out->tm_min = (int)(rem % 3600 / 60);
    out->tm_sec = (int)(rem % 60);
    out->tm_wday = (int)floor_mod(days + 4, 7); /* 1970-01-01 was a Thursday */
    int64_t y;
    int m, d;
    civil_from_days(days, &y, &m, &d);
    out->tm_year = (int)(y - 1900);
    if (y - 1900 > 2147483647LL || y - 1900 < -2147483648LL) return 0;
    out->tm_yday = (int)(days - days_from_civil(y, 1, 1));
    out->tm_mon = m - 1;
    out->tm_mday = d;
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

/* ---- asctime / ctime ----------------------------------------------------------------------------------------- */

/* The longest text is 67 characters (the widest possible fields); 80 leaves room for the newline and NUL. */
#define ASCTIME_STATIC 80

/* printf("%*.*d"): at least `min_digits` digits (zero filled), a '-' for a negative value, and the whole thing right
 * aligned in `width` columns with spaces. Returns the characters written. */
static size_t put_int(char *dst, int value, int min_digits, int width) {
    char tmp[16];
    size_t len = 0;
    int neg = value < 0;
    unsigned mag = neg ? 0u - (unsigned)value : (unsigned)value;
    do { tmp[len++] = (char)('0' + mag % 10); mag /= 10; } while (mag != 0);
    while ((int)len < min_digits) tmp[len++] = '0';
    if (neg) tmp[len++] = '-';
    size_t fill = (int)len < width ? (size_t)width - len : 0;
    size_t out = 0;
    while (out < fill) dst[out++] = ' ';
    for (size_t k = 0; k < len; k++) dst[out + k] = tmp[len - 1 - k];
    return out + len;
}

/* "%.3s %.3s%3d %.2d:%.2d:%.2d %d\n" with "???" for names out of range. -1 when tm_year + 1900 overflows an int. */
static int asctime_text(const struct tm *tm, char *dst, size_t *len_out) {
    static const char days[7][4] = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"};
    static const char mons[12][4] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};
    int year;
    if (__builtin_add_overflow(tm->tm_year, 1900, &year)) return -1;
    size_t n = 0;
    const char *d = (tm->tm_wday >= 0 && tm->tm_wday <= 6) ? days[tm->tm_wday] : "???";
    const char *m = (tm->tm_mon >= 0 && tm->tm_mon <= 11) ? mons[tm->tm_mon] : "???";
    memcpy(dst + n, d, 3); n += 3;
    dst[n++] = ' ';
    memcpy(dst + n, m, 3); n += 3;
    n += put_int(dst + n, tm->tm_mday, 1, 3);
    dst[n++] = ' ';
    n += put_int(dst + n, tm->tm_hour, 2, 0);
    dst[n++] = ':';
    n += put_int(dst + n, tm->tm_min, 2, 0);
    dst[n++] = ':';
    n += put_int(dst + n, tm->tm_sec, 2, 0);
    dst[n++] = ' ';
    n += put_int(dst + n, year, 1, 0);
    dst[n++] = '\n';
    dst[n] = '\0';
    *len_out = n;
    return 0;
}

static char asctime_buf[ASCTIME_STATIC];

char *asctime(const struct tm *tm) {
    if (!tm) {
        errno = EINVAL;
        return (char *)0;
    }
    size_t n;
    if (asctime_text(tm, asctime_buf, &n) != 0) {
        errno = EOVERFLOW;
        return (char *)0;
    }
    return asctime_buf;
}

char *asctime_r(const struct tm *tm, char *buf) {
    if (!tm || !buf) {
        errno = EINVAL;
        return (char *)0;
    }
    char tmp[ASCTIME_STATIC];
    size_t n;
    if (asctime_text(tm, tmp, &n) != 0) {
        errno = EOVERFLOW;
        return (char *)0;
    }
    /* At most 26 bytes: a longer text is cut to 25 characters and a NUL, and the call fails. */
    if (n >= 26) {
        memcpy(buf, tmp, 25);
        buf[25] = '\0';
        errno = EOVERFLOW;
        return (char *)0;
    }
    memcpy(buf, tmp, n + 1);
    return buf;
}

char *ctime(const time_t *t) {
    struct tm *g = localtime(t);
    if (!g) return asctime((const struct tm *)0); /* EINVAL, as glibc: localtime's EOVERFLOW is replaced */
    return asctime(g);
}

char *ctime_r(const time_t *t, char *buf) {
    struct tm g;
    if (!localtime_r(t, &g)) return asctime_r((const struct tm *)0, buf);
    return asctime_r(&g, buf);
}

/* ---- strptime ---------------------------------------------------------------------------------------------------- */

/* PROVENANCE AND LICENSE NOTICE (read before reusing or redistributing this section).
 *
 * Everything from here to the end of the file follows the structure of the GNU C Library's time/strptime_l.c
 * (Copyright (C) 2002-2026 Free Software Foundation, Inc., LGPL-2.1-or-later): the NUMBER and RECURSE helpers, the
 * day_of_the_week closed formula and its constants, the __mon_yday table and the %U/%W day-of-year formula, and the
 * pending-state bits. The behavior was first measured against a running glibc and checked with a differential test;
 * the glibc source was read afterwards, to confirm the selection-state transitions, and this code was then written
 * to match it. Treat this section as derived from glibc for licensing purposes. The rest of this file (gmtime,
 * timegm, mktime, strftime, asctime, ctime) was written from measured behavior and does not copy glibc source.
 *
 * The repository's LICENSE (GPLv3) and README (MIT) disagree with each other; LGPL-2.1-or-later code may be combined
 * into a GPLv3 work but not placed under MIT terms. The owner needs to decide whether to keep this section, rewrite it
 * clean-room, or remove it. See docs/current-code-review-and-fix-plan.md. */

/* glibc's __mon_yday: cumulative days before each month, ordinary year then leap year, read as one flat array (glibc's
 * %j handling walks past the end of the first row into the second one for day 366 of a non-leap year). A zero sits in
 * front because glibc reads __mon_yday[0][-1] for a negative day of year, which is a zero in its data segment; reads
 * past the end give a value too large for any day, so a search over the table always stops. */
static const short mon_yday_flat_tab[1 + 26] = {
    0,
    0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365,
    0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335, 366,
};
static int mon_yday_flat(int index) {
    if (index < -1) return 0;
    if (index > 25) return 0x7fffffff;
    return mon_yday_flat_tab[index + 1];
}
static int mon_yday_at(int leap, int month) { return mon_yday_flat(leap * 13 + month); }

static int is_leap_year(int y) { return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0); }

struct pstate {
    int have_I, is_pm, century, want_century, want_era, want_xday;
    int have_wday, have_yday, have_mon, have_mday, have_uweek, have_wweek, week_no;
    /* Which representation the call has committed to: 0 not yet, 1 "alternative" (a numeric %O was read), 2 "plain" (a
     * %E year/century conversion fell back to the plain one). The C locale has no alternative digits and no eras, so
     * once the call is in state 1 every later numeric %O and every %E year/century conversion fails (measured). */
    int decided;
};
#define DECIDED_NOT 0
#define DECIDED_ALT 1
#define DECIDED_RAW 2

static int is_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'; }

/* Weekday from year, month and day, by the same closed formula glibc uses. It runs in 32-bit int arithmetic and glibc's
 * result for years in the millions depends on that wrapping (a wider computation gives a different weekday there), so
 * the arithmetic here wraps the same way (done unsigned to stay well defined). */
static int wrap_mul(int a, int b) { return (int)((unsigned)a * (unsigned)b); }

static void day_of_the_week(struct tm *tm) {
    int corr_year = wrap_sub(wrap_add(1900, tm->tm_year), tm->tm_mon < 2);
    int q = corr_year / 4;
    int wday = -473;
    wday = wrap_add(wday, wrap_mul(365, wrap_sub(tm->tm_year, 70)));
    wday = wrap_add(wday, q);
    wday = wrap_sub(wday, q / 25);
    wday = wrap_add(wday, q % 25 < 0);
    wday = wrap_add(wday, (q / 25) / 4);
    wday = wrap_add(wday, mon_yday_flat(tm->tm_mon));
    wday = wrap_add(wday, wrap_sub(tm->tm_mday, 1));
    tm->tm_wday = ((wday % 7) + 7) % 7;
}

static void day_of_the_year(struct tm *tm) {
    tm->tm_yday = mon_yday_at(is_leap_year(1900 + tm->tm_year), tm->tm_mon) + (tm->tm_mday - 1);
}

/* The day-of-year to month/day-of-month step, shared by %j and the week-number paths. glibc runs the table lookup off
 * the end for day 366 of a non-leap year, and so does this (see mon_yday). */
static void yday_to_mon_mday(struct tm *tm, int set_mon, int set_mday) {
    int leap = is_leap_year(1900 + tm->tm_year);
    int t_mon = 0;
    while (mon_yday_at(leap, t_mon) <= tm->tm_yday) t_mon++;
    if (set_mon) tm->tm_mon = t_mon - 1;
    if (set_mday) tm->tm_mday = tm->tm_yday - mon_yday_at(leap, t_mon - 1) + 1;
}

static int match_name(const char **rp, const char *name) {
    const char *a = *rp;
    const char *b = name;
    while (*b) {
        if (low(*a) != low(*b)) return 0;
        a++; b++;
    }
    *rp = a;
    return 1;
}

/* The first three letters of a name, case-insensitively (the abbreviated day or month). */
static int match_abbr(const char **rp, const char *name) {
    char three[4] = { name[0], name[1], name[2], 0 };
    return match_name(rp, three);
}

static const char *strptime_core(const char *rp, const char *fmt, struct tm *tm, struct pstate *s, int nested);

#define NUMBER(from, to, n) do { \
        int count_ = (n); \
        val = 0; \
        while (is_space(*rp)) rp++; \
        if (*rp < '0' || *rp > '9') return (const char *)0; \
        do { val *= 10; val += *rp++ - '0'; } while (--count_ > 0 && val * 10 <= (to) && *rp >= '0' && *rp <= '9'); \
        if (val < (from) || val > (to)) return (const char *)0; \
    } while (0)

/* glibc parses the expansion of a composite conversion into a scratch copy of the struct and the pending state, and only
 * keeps them when the whole expansion matched: a failed %T leaves the caller's tm exactly as it was. */
#define RECURSE(sub) do { \
        struct tm scratch_ = *tm; \
        struct pstate scratch_s_ = *s; \
        const char *next_ = strptime_core(rp, (sub), &scratch_, &scratch_s_, 1); \
        if (!next_) return (const char *)0; \
        *tm = scratch_; \
        *s = scratch_s_; \
        rp = next_; \
    } while (0)

static const char *strptime_core(const char *rp, const char *fmt, struct tm *tm, struct pstate *s, int nested) {
    int val;
    while (*fmt != '\0') {
        if (is_space(*fmt)) {
            while (is_space(*rp)) rp++;
            fmt++;
            continue;
        }
        if (*fmt != '%') {
            if (*fmt++ != *rp++) return (const char *)0;
            continue;
        }
        fmt++;
        /* strftime flags and a field width are accepted and ignored. */
        while (*fmt == '-' || *fmt == '_' || *fmt == '0' || *fmt == '^' || *fmt == '#') fmt++;
        if (*fmt >= '0' && *fmt <= '9') {
            do { fmt++; } while (*fmt >= '0' && *fmt <= '9');
        }
        char conv = *fmt++;
        char mod = 0;
        if (conv == 'E' || conv == 'O') {
            mod = conv;
            conv = *fmt++;
            static const char e_set[] = "CXYcxy";
            static const char o_set[] = "BHIMSUVWbdehmwy";
            const char *set = mod == 'E' ? e_set : o_set;
            int ok = 0;
            for (; *set; set++) if (*set == conv) ok = 1;
            if (!ok) return (const char *)0;
            /* A numeric %O conversion tries the (absent) alternative digits first: the first one commits the call to
             * state ALT and reads the digits normally, a later one then finds no alternative digits and fails. After a
             * %E year/century conversion (state RAW) it just reads digits. The names (B b h) do not touch the state. */
            if (mod == 'O' && conv != 'B' && conv != 'b' && conv != 'h') {
                if (s->decided == DECIDED_ALT) return (const char *)0;
                if (s->decided == DECIDED_NOT) s->decided = DECIDED_ALT;
            }
        }
        switch (conv) {
        case '%':
            if (*rp++ != '%') return (const char *)0;
            break;
        case 'a':
        case 'A': {
            /* Two passes over the seven days, as glibc does: with the call not committed to the plain representation
             * the "locale" names are tried (identical to the plain ones in the C locale) and a longer match wins; unless
             * committed to the alternative one, the plain names are tried as well. glibc's plain pass hands the
             * abbreviated-name matcher the input pointer itself rather than a copy, so each abbreviation hit also moves
             * the input position for the following days, and a call already in the plain state ends up not consuming an
             * abbreviated name at all. Reproduced exactly (measured against glibc). */
            const char *longest = (const char *)0;
            int cnt_longest = -1;
            for (int cnt = 0; cnt < 7; cnt++) {
                const char *trp;
                if (s->decided != DECIDED_RAW) {
                    trp = rp;
                    if (match_name(&trp, day_long[cnt]) && trp > longest) { longest = trp; cnt_longest = cnt; }
                    trp = rp;
                    if (match_abbr(&trp, day_long[cnt]) && trp > longest) { longest = trp; cnt_longest = cnt; }
                }
                if (s->decided != DECIDED_ALT) {
                    trp = rp;
                    int hit = match_name(&trp, day_long[cnt]) && trp > longest;
                    if (!hit) {
                        trp = rp;
                        hit = match_abbr(&rp, day_long[cnt]) && trp > longest;
                    }
                    if (hit) { longest = trp; cnt_longest = cnt; s->decided = DECIDED_RAW; }
                }
            }
            if (!longest) return (const char *)0;
            rp = longest;
            tm->tm_wday = cnt_longest;
            s->have_wday = 1;
            break;
        }
        case 'b':
        case 'B':
        case 'h': {
            const char *longest = (const char *)0;
            int cnt_longest = -1;
            for (int cnt = 0; cnt < 12; cnt++) {
                const char *trp;
                if (s->decided != DECIDED_RAW) {
                    trp = rp;
                    if (match_name(&trp, month_long[cnt]) && trp > longest) { longest = trp; cnt_longest = cnt; }
                    trp = rp;
                    if (match_abbr(&trp, month_long[cnt]) && trp > longest) { longest = trp; cnt_longest = cnt; }
                }
                if (s->decided != DECIDED_ALT) {
                    trp = rp;
                    int hit = match_name(&trp, month_long[cnt]) && trp > longest;
                    if (!hit) {
                        trp = rp;
                        hit = match_abbr(&trp, month_long[cnt]) && trp > longest;
                    }
                    if (hit) { longest = trp; cnt_longest = cnt; s->decided = DECIDED_RAW; }
                }
            }
            if (!longest) return (const char *)0;
            rp = longest;
            tm->tm_mon = cnt_longest;
            s->have_mon = 1;
            s->want_xday = 1;
            break;
        }
        case 'c':
            RECURSE("%a %b %e %H:%M:%S %Y");
            s->want_xday = 1;
            break;
        case 'C':
            if (mod == 'E') {
                if (s->decided == DECIDED_ALT) return (const char *)0;
                s->decided = DECIDED_RAW;
            }
            NUMBER(0, 99, 2);
            s->century = val;
            s->want_xday = 1;
            break;
        case 'd':
        case 'e':
            NUMBER(1, 31, 2);
            tm->tm_mday = val;
            s->have_mday = 1;
            s->want_xday = 1;
            break;
        case 'F':
            RECURSE("%Y-%m-%d");
            s->want_xday = 1;
            break;
        case 'x':
        case 'D':
            RECURSE("%m/%d/%y");
            s->want_xday = 1;
            break;
        case 'k':
        case 'H':
            NUMBER(0, 23, 2);
            tm->tm_hour = val;
            s->have_I = 0;
            break;
        case 'I':
        case 'l':
            NUMBER(1, 12, 2);
            tm->tm_hour = val % 12;
            s->have_I = 1;
            break;
        case 'j':
            NUMBER(1, 366, 3);
            tm->tm_yday = val - 1;
            s->have_yday = 1;
            break;
        case 'm':
            NUMBER(1, 12, 2);
            tm->tm_mon = val - 1;
            s->have_mon = 1;
            s->want_xday = 1;
            break;
        case 'M':
            NUMBER(0, 59, 2);
            tm->tm_min = val;
            break;
        case 'n':
        case 't':
            while (is_space(*rp)) rp++;
            break;
        case 'p':
            if (match_name(&rp, "AM")) s->is_pm = 0;
            else if (match_name(&rp, "PM")) s->is_pm = 1;
            else return (const char *)0;
            break;
        case 'r':
            RECURSE("%I:%M:%S %p");
            break;
        case 'R':
            RECURSE("%H:%M");
            break;
        case 's': {
            unsigned long long secs = 0;
            if (*rp < '0' || *rp > '9') return (const char *)0;
            do { secs = secs * 10 + (unsigned long long)(*rp++ - '0'); } while (*rp >= '0' && *rp <= '9');
            time_t t = (time_t)secs;
            if (!localtime_r(&t, tm)) return (const char *)0;
            break;
        }
        case 'S':
            NUMBER(0, 61, 2);
            tm->tm_sec = val;
            break;
        case 'X':
        case 'T':
            RECURSE("%H:%M:%S");
            break;
        case 'u':
            NUMBER(1, 7, 1);
            tm->tm_wday = val % 7;
            s->have_wday = 1;
            break;
        case 'g':
            NUMBER(0, 99, 2);
            break; /* cannot determine any field */
        case 'G':
            if (*rp < '0' || *rp > '9') return (const char *)0;
            do { rp++; } while (*rp >= '0' && *rp <= '9');
            break;
        case 'U':
            NUMBER(0, 53, 2);
            s->week_no = val;
            s->have_uweek = 1;
            break;
        case 'W':
            NUMBER(0, 53, 2);
            s->week_no = val;
            s->have_wweek = 1;
            break;
        case 'V':
            NUMBER(0, 53, 2);
            break;
        case 'w':
            NUMBER(0, 6, 1);
            tm->tm_wday = val;
            s->have_wday = 1;
            break;
        case 'y':
            if (mod == 'E' && s->decided != DECIDED_RAW) {
                /* In the C locale %Ey reads a 0..9999 number of up to four digits and stores it in tm_year; then, having
                 * found no era, it falls into plain %y and reads a second number. Once the call is in state RAW (an
                 * earlier %E year/century conversion) the first number is skipped. In state ALT it fails after storing. */
                NUMBER(0, 9999, 4);
                tm->tm_year = val;
                s->want_era = 1;
                s->want_xday = 1;
                s->want_century = 1;
                if (s->decided == DECIDED_ALT) return (const char *)0;
                s->decided = DECIDED_RAW;
            }
            NUMBER(0, 99, 2);
            tm->tm_year = val >= 69 ? val : val + 100;
            /* %Oy does not mark the year as "within a century": a later %C then replaces the whole year. */
            if (mod != 'O') s->want_century = 1;
            s->want_xday = 1;
            break;
        case 'Y':
            if (mod == 'E') {
                if (s->decided == DECIDED_ALT) return (const char *)0;
                s->decided = DECIDED_RAW;
            }
            NUMBER(0, 9999, 4);
            tm->tm_year = val - 1900;
            s->want_century = 0;
            s->want_xday = 1;
            break;
        case 'Z':
            /* A zone name is read and ignored. */
            while (is_space(*rp)) rp++;
            while (!is_space(*rp) && *rp != '\0') rp++;
            break;
        case 'z': {
            val = 0;
            while (is_space(*rp)) rp++;
            if (*rp == 'Z') {
                rp++;
                tm->tm_gmtoff = 0;
                break;
            }
            if (*rp != '+' && *rp != '-') return (const char *)0;
            int neg = *rp++ == '-';
            int n = 0;
            while (n < 4 && *rp >= '0' && *rp <= '9') {
                val = val * 10 + *rp++ - '0';
                n++;
                if (*rp == ':' && n == 2 && rp[1] >= '0' && rp[1] <= '9') rp++;
            }
            if (n == 2) val *= 100;
            else if (n != 4) return (const char *)0;
            else if (val % 100 >= 60) return (const char *)0;
            tm->tm_gmtoff = (val / 100) * 3600L + (val % 100) * 60L;
            if (neg) tm->tm_gmtoff = -tm->tm_gmtoff;
            break;
        }
        default:
            return (const char *)0;
        }
    }
    if (nested) return rp;

    if (s->have_I && s->is_pm) tm->tm_hour += 12;
    if (s->century != -1) {
        if (s->want_century) tm->tm_year = tm->tm_year % 100 + (s->century - 19) * 100;
        else tm->tm_year = (s->century - 19) * 100;
    } else if (s->want_era) {
        /* An E modifier was seen but no era applies in the C locale. */
        if (s->want_century && s->century == -1 && tm->tm_year < 69) tm->tm_year += 100;
    }
    if (s->want_xday && !s->have_wday) {
        if (!(s->have_mon && s->have_mday) && s->have_yday) {
            yday_to_mon_mday(tm, !s->have_mon, !s->have_mday);
            s->have_mon = 1;
            s->have_mday = 1;
        }
        if (s->have_mon || (unsigned)tm->tm_mon <= 11) day_of_the_week(tm);
    }
    if (s->want_xday && !s->have_yday && (s->have_mon || (unsigned)tm->tm_mon <= 11)) day_of_the_year(tm);
    if ((s->have_uweek || s->have_wweek) && s->have_wday) {
        int save_wday = tm->tm_wday;
        int save_mday = tm->tm_mday;
        int save_mon = tm->tm_mon;
        int w_offset = s->have_uweek ? 0 : 1;
        tm->tm_mday = 1;
        tm->tm_mon = 0;
        day_of_the_week(tm);
        if (s->have_mday) tm->tm_mday = save_mday;
        if (s->have_mon) tm->tm_mon = save_mon;
        if (!s->have_yday) {
            tm->tm_yday = (7 - (tm->tm_wday - w_offset)) % 7 + (s->week_no - 1) * 7 + (save_wday - w_offset + 7) % 7;
        }
        if (!s->have_mday || !s->have_mon) yday_to_mon_mday(tm, !s->have_mon, !s->have_mday);
        tm->tm_wday = save_wday;
    }
    return rp;
}

char *strptime(const char *buf, const char *format, struct tm *tm) {
    struct pstate s = { 0, 0, -1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, DECIDED_NOT };
    return (char *)strptime_core(buf, format, tm, &s, 0);
}
