/* Calendar conversion and strftime, checked against values measured with glibc (TZ=UTC, C locale). The expectations
 * are written out, not computed, so the test does not depend on the machine that runs it. */
#include <assert.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "../include/errno.h"
#include "../include/time.h"

static int errno_slot;
int *__errno_location(void) { return &errno_slot; }

static void check_tm(const struct tm *t, int y, int mo, int d, int h, int mi, int s, int wd, int yd) {
    assert(t->tm_year + 1900 == y && t->tm_mon + 1 == mo && t->tm_mday == d);
    assert(t->tm_hour == h && t->tm_min == mi && t->tm_sec == s && t->tm_wday == wd && t->tm_yday == yd);
}

static size_t fmt(char *buf, size_t cap, const char *f, const struct tm *t) {
    memset(buf, '#', cap);
    return strftime(buf, cap, f, t);
}

#define EXPECT(f, want) do { char b[160]; size_t n = fmt(b, sizeof b, (f), &T); \
    assert(n == strlen(want) && memcmp(b, want, n) == 0 && b[n] == '\0'); } while (0)

int main(void) {
    /* struct tm is glibc's: 56 bytes, tm_gmtoff and tm_zone after tm_isdst. */
    assert(sizeof(struct tm) == 56);
    assert(offsetof(struct tm, tm_sec) == 0 && offsetof(struct tm, tm_min) == 4 && offsetof(struct tm, tm_hour) == 8);
    assert(offsetof(struct tm, tm_mday) == 12 && offsetof(struct tm, tm_mon) == 16 && offsetof(struct tm, tm_year) == 20);
    assert(offsetof(struct tm, tm_wday) == 24 && offsetof(struct tm, tm_yday) == 28 && offsetof(struct tm, tm_isdst) == 32);
    assert(offsetof(struct tm, tm_gmtoff) == 40 && offsetof(struct tm, tm_zone) == 48);
    assert(EOVERFLOW == 75);

    /* gmtime_r: measured values. */
    struct tm t;
    time_t v;
    v = 0;           assert(gmtime_r(&v, &t) == &t); check_tm(&t, 1970, 1, 1, 0, 0, 0, 4, 0);
    assert(t.tm_isdst == 0 && t.tm_gmtoff == 0 && strcmp(t.tm_zone, "GMT") == 0);
    v = -1;          assert(gmtime_r(&v, &t)); check_tm(&t, 1969, 12, 31, 23, 59, 59, 3, 364);
    v = 86399;       assert(gmtime_r(&v, &t)); check_tm(&t, 1970, 1, 1, 23, 59, 59, 4, 0);
    v = 86400;       assert(gmtime_r(&v, &t)); check_tm(&t, 1970, 1, 2, 0, 0, 0, 5, 1);
    v = 951782400;   assert(gmtime_r(&v, &t)); check_tm(&t, 2000, 2, 29, 0, 0, 0, 2, 59);
    v = 951868800;   assert(gmtime_r(&v, &t)); check_tm(&t, 2000, 3, 1, 0, 0, 0, 3, 60);
    v = 4107542400L; assert(gmtime_r(&v, &t)); check_tm(&t, 2100, 3, 1, 0, 0, 0, 1, 59); /* 2100 is not a leap year */
    v = -2208988800L; assert(gmtime_r(&v, &t)); check_tm(&t, 1900, 1, 1, 0, 0, 0, 1, 0);
    v = -62135596800L; assert(gmtime_r(&v, &t)); check_tm(&t, 1, 1, 1, 0, 0, 0, 1, 0);
    v = 1700000000;  assert(gmtime_r(&v, &t)); check_tm(&t, 2023, 11, 14, 22, 13, 20, 2, 317);
    v = 2147483647;  assert(gmtime_r(&v, &t)); check_tm(&t, 2038, 1, 19, 3, 14, 7, 2, 18);
    v = 2147483648L; assert(gmtime_r(&v, &t)); check_tm(&t, 2038, 1, 19, 3, 14, 8, 2, 18);
    v = -2147483648L; assert(gmtime_r(&v, &t)); check_tm(&t, 1901, 12, 13, 20, 45, 52, 5, 346);
    v = 253402300799L; assert(gmtime_r(&v, &t)); check_tm(&t, 9999, 12, 31, 23, 59, 59, 5, 364);
    /* The extremes: the last representable year is exactly 2147483647 (tm_year is an int), one more second is EOVERFLOW. */
    v = 67768036191676799L; assert(gmtime_r(&v, &t));
    assert(t.tm_year == 2147483647 && t.tm_mon == 11 && t.tm_mday == 31 && t.tm_hour == 23 && t.tm_min == 59 && t.tm_sec == 59);
    assert(t.tm_wday == 3 && t.tm_yday == 364);
    errno_slot = 0;
    v = 67768036191676800L; assert(gmtime_r(&v, &t) == NULL && errno_slot == EOVERFLOW);
    v = -67768040609740800L; assert(gmtime_r(&v, &t) && t.tm_year == -2147483648);
    errno_slot = 0;
    v = -67768040609740801L; assert(gmtime_r(&v, &t) == NULL && errno_slot == EOVERFLOW);
    errno_slot = 0;
    v = (time_t)1 << 62; assert(gmtime_r(&v, &t) == NULL && errno_slot == EOVERFLOW);
    errno_slot = 0;
    v = -((time_t)1 << 62); assert(gmtime_r(&v, &t) == NULL && errno_slot == EOVERFLOW);
    /* A failed conversion leaves errno alone on success. */
    errno_slot = 77; v = 0; assert(gmtime_r(&v, &t) && errno_slot == 77);
    /* The non-reentrant forms use static storage and agree. */
    { struct tm *p = gmtime(&v); assert(p && p->tm_year == 70 && p == gmtime(&v)); }
    { struct tm *p = localtime(&v); assert(p && p->tm_year == 70 && p->tm_hour == 0); }
    { struct tm *p = localtime_r(&v, &t); assert(p == &t && t.tm_hour == 0 && t.tm_gmtoff == 0); }

    /* timegm / mktime normalise out-of-range fields (all cases measured; the zone is UTC). */
    struct { int y, mo, d, h, mi, s; long want; int ey, em, ed, eh, emi, es, ewd, eyd; } m[] = {
        {2000, 0, 1, 0, 0, 0, 946684800L, 2000, 1, 1, 0, 0, 0, 6, 0},
        {2000, 12, 1, 0, 0, 0, 978307200L, 2001, 1, 1, 0, 0, 0, 1, 0},
        {2000, -1, 1, 0, 0, 0, 944006400L, 1999, 12, 1, 0, 0, 0, 3, 334},
        {2000, 0, 0, 0, 0, 0, 946598400L, 1999, 12, 31, 0, 0, 0, 5, 364},
        {2000, 0, 32, 0, 0, 0, 949363200L, 2000, 2, 1, 0, 0, 0, 2, 31},
        {2000, 1, 30, 0, 0, 0, 951868800L, 2000, 3, 1, 0, 0, 0, 3, 60},
        {2000, 0, 1, 24, 0, 0, 946771200L, 2000, 1, 2, 0, 0, 0, 0, 1},
        {2000, 0, 1, 0, 60, 0, 946688400L, 2000, 1, 1, 1, 0, 0, 6, 0},
        {2000, 0, 1, 0, 0, -1, 946684799L, 1999, 12, 31, 23, 59, 59, 5, 364},
        {2000, 0, 1, 0, 0, 86400, 946771200L, 2000, 1, 2, 0, 0, 0, 0, 1},
        {1969, 11, 31, 23, 59, 59, -1L, 1969, 12, 31, 23, 59, 59, 3, 364},
        {1900, 0, 1, 0, 0, 0, -2208988800L, 1900, 1, 1, 0, 0, 0, 1, 0},
        {2100, 1, 29, 0, 0, 0, 4107542400L, 2100, 3, 1, 0, 0, 0, 1, 59},
        {2024, 1, 29, 12, 0, 0, 1709208000L, 2024, 2, 29, 12, 0, 0, 4, 59},
        {-1000, 0, 1, 0, 0, 0, -93724128000L, -1000, 1, 1, 0, 0, 0, 3, 0},
        {100000, 0, 1, 0, 0, 0, 3093527980800L, 100000, 1, 1, 0, 0, 0, 6, 0},
    };
    for (unsigned i = 0; i < sizeof m / sizeof m[0]; i++) {
        for (int pass = 0; pass < 2; pass++) {
            memset(&t, 0, sizeof t);
            t.tm_year = m[i].y - 1900; t.tm_mon = m[i].mo; t.tm_mday = m[i].d;
            t.tm_hour = m[i].h; t.tm_min = m[i].mi; t.tm_sec = m[i].s; t.tm_isdst = -1;
            t.tm_wday = 99; t.tm_yday = 999;
            time_t r = pass ? mktime(&t) : timegm(&t);
            assert(r == m[i].want);
            check_tm(&t, m[i].ey, m[i].em, m[i].ed, m[i].eh, m[i].emi, m[i].es, m[i].ewd, m[i].eyd);
            assert(t.tm_isdst == 0 && t.tm_gmtoff == 0);
        }
    }
    /* mktime with tm_isdst > 0 takes the time as daylight saving time and so returns an hour earlier, even though the
     * zone has no DST (measured: 2000-01-01 05:00 gives 946702800 with isdst -1/0/INT_MIN and 946699200 with 1, 2, 7,
     * INT_MAX); the normalised tm then shows 04:00 with tm_isdst 0. timegm ignores tm_isdst altogether. */
    {
        static const int isd[] = {-5, -1, 0, 1, 2, 7, 2147483647, -2147483647 - 1};
        static const long want[] = {946702800L, 946702800L, 946702800L, 946699200L, 946699200L, 946699200L, 946699200L, 946702800L};
        for (unsigned i = 0; i < sizeof isd / sizeof isd[0]; i++) {
            memset(&t, 0, sizeof t); t.tm_year = 100; t.tm_mday = 1; t.tm_hour = 5; t.tm_isdst = isd[i];
            assert(mktime(&t) == want[i] && t.tm_isdst == 0 && t.tm_hour == (want[i] == 946699200L ? 4 : 5));
            memset(&t, 0, sizeof t); t.tm_year = 100; t.tm_mday = 1; t.tm_hour = 5; t.tm_isdst = isd[i];
            assert(timegm(&t) == 946702800L && t.tm_hour == 5 && t.tm_isdst == 0);
        }
        /* The hour shift is applied before the range check: the last second with isdst 1 is an hour earlier, the first
         * representable second with isdst 1 no longer fits. */
        memset(&t, 0, sizeof t); t.tm_year = 2147483647; t.tm_mon = 11; t.tm_mday = 31; t.tm_hour = 23; t.tm_min = 59; t.tm_sec = 59; t.tm_isdst = 1;
        assert(mktime(&t) == 67768036191673199LL);
        memset(&t, 0, sizeof t); t.tm_year = -2147483647 - 1; t.tm_mday = 1; t.tm_isdst = 1;
        t.tm_wday = 3; t.tm_yday = 9; t.tm_gmtoff = 77; t.tm_zone = "Q";
        { struct tm same = t; errno_slot = 0;
          assert(mktime(&t) == (time_t)-1 && errno_slot == EOVERFLOW);
          assert(memcmp(&t, &same, sizeof t) == 0); } /* mktime leaves *tm exactly as it was, tm_isdst included */
        { struct tm over; memset(&over, 0, sizeof over); over.tm_year = 2147483647; over.tm_mon = 11; over.tm_mday = 32; over.tm_isdst = 1;
          over.tm_wday = 3; over.tm_yday = 9; over.tm_gmtoff = 77; over.tm_zone = "Q";
          struct tm same = over, g = over; errno_slot = 0;
          assert(mktime(&over) == (time_t)-1 && errno_slot == EOVERFLOW && memcmp(&over, &same, sizeof over) == 0);
          errno_slot = 0; same.tm_isdst = 0; /* timegm clears tm_isdst and nothing else */
          assert(timegm(&g) == (time_t)-1 && errno_slot == EOVERFLOW && memcmp(&g, &same, sizeof g) == 0); }
        memset(&t, 0, sizeof t); t.tm_year = -2147483647 - 1; t.tm_mday = 1; t.tm_isdst = 0;
        assert(mktime(&t) == -67768040609740800LL);
    }
    /* The zone fields after timegm of the epoch are GMT / 0. */
    memset(&t, 0, sizeof t); t.tm_year = 70; t.tm_mday = 1;
    assert(timegm(&t) == 0 && strcmp(t.tm_zone, "GMT") == 0 && t.tm_gmtoff == 0);
    /* Overflow in either direction is -1 / EOVERFLOW and only clears tm_isdst. */
    {
        /* The edges of tm_year, measured with glibc. tm_mday 0 is the day before the 1st, so INT_MIN years with mday 0
         * falls in the year before the smallest representable one. */
        struct { int y, mo, d, h, mi, sec; long long want; int err; } o[] = {
            {2147483647, 11, 31, 0, 0, 0, 67768036191590400LL, 0},
            {2147483647, 11, 31, 23, 59, 59, 67768036191676799LL, 0},   /* the last representable second */
            {2147483647, 11, 31, 24, 0, 0, -1, EOVERFLOW},              /* one second later */
            {2147483647, 12, 1, 0, 0, 0, -1, EOVERFLOW},                /* the month carries into a year that does not fit an int */
            {2147483646, 12, 1, 0, 0, 0, 67768036160140800LL, 0},       /* ...but one year earlier it fits */
            {2147483647, -12, 1, 0, 0, 0, 67768036128604800LL, 0},
            {-2147483647 - 1, 0, 1, 0, 0, 0, -67768040609740800LL, 0},   /* the first representable second */
            {-2147483647 - 1, 0, 0, 0, 0, 0, -1, EOVERFLOW},            /* tm_mday 0 is the day before it */
            {-2147483647 - 1, 0, 1, 0, 0, -1, -1, EOVERFLOW},           /* one second before it */
            {-2147483647 - 1, 0, 1, 0, 0, 1, -67768040609740799LL, 0},
            {-2147483647 - 1, 11, 31, 23, 59, 59, -67768040578118401LL, 0},
            {-2147483647 - 1, 12, 1, 0, 0, 0, -67768040578118400LL, 0}, /* the month carries up into the next year */
            {-2147483647, -1, 1, 0, 0, 0, -67768040580796800LL, 0},
            {2147483647, 11, 2147483647, 2147483647, 2147483647, 2147483647, -1, EOVERFLOW},
            {-2147483647 - 1, 0, -2147483647 - 1, -2147483647 - 1, -2147483647 - 1, -2147483647 - 1, -1, EOVERFLOW},
            {70, -2147483647 - 1, 1, 0, 0, 0, -5647336533504000LL, 0},
            {70, 2147483647, 1, 0, 0, 0, 5647336530739200LL, 0},
            {70, 0, 2147483647, 0, 0, 0, 185542587014400LL, 0},
            {70, 0, -2147483647 - 1, 0, 0, 0, -185542587273600LL, 0},
            {70, 0, 1, -2147483647 - 1, 0, 0, -7730941132800LL, 0},
            {70, 0, 1, 0, 0, -2147483647 - 1, -2147483648LL, 0},
        };
        for (unsigned i = 0; i < sizeof o / sizeof o[0]; i++) {
            memset(&t, 0, sizeof t);
            t.tm_year = o[i].y; t.tm_mon = o[i].mo; t.tm_mday = o[i].d;
            t.tm_hour = o[i].h; t.tm_min = o[i].mi; t.tm_sec = o[i].sec;
            struct tm before = t;
            before.tm_isdst = 0; /* on overflow glibc clears tm_isdst and changes nothing else (measured) */
            errno_slot = 0;
            time_t r = timegm(&t);
            assert((long long)r == o[i].want && errno_slot == o[i].err);
            if (o[i].err) assert(memcmp(&t, &before, sizeof t) == 0);
        }
        memset(&t, 0, sizeof t); t.tm_year = 70; t.tm_sec = 2147483647; t.tm_min = 2147483647; t.tm_hour = 2147483647;
        errno_slot = 0;
        assert(timegm(&t) == 7861937545267LL && errno_slot == 0);
        /* tm_mday left at 0 (memset): the day before the 1st, hence the 86400 seconds less than the table's mday 1 rows. */
        memset(&t, 0, sizeof t); t.tm_year = 70; t.tm_mon = -2147483647 - 1;
        assert(timegm(&t) == -5647336533590400LL);
        memset(&t, 0, sizeof t); t.tm_year = 70; t.tm_mon = 2147483647;
        assert(timegm(&t) == 5647336530652800LL);
    }
    /* Range checks happen on the date+hour+minute total first, then with the seconds (and for mktime with tm_isdst > 0
     * the hour that comes off): an intermediate that is out of range fails even when the seconds would bring the answer
     * back. Every row below was measured with glibc; `dst` only matters to mktime. */
    {
        struct { int y, mo, d, h, mi, sec, dst; long long tg, mk; } ed[] = {
            /* timegm result (or -1), mktime result (or -1); -1 here always means EOVERFLOW. */
            {2147483646, 1, -2, 86400, 30, -2147483647 - 1, -1, -1, -1},
            {2147483646, 0, 1, 0, 0, -2147483647 - 1, -1, 67768033981121152LL, 67768033981121152LL},
            {2147483647, 11, 31, 23, 59, 60, 2, -1, 67768036191673200LL},
            {2147483647, 11, 31, 23, 59, 60, 0, -1, -1},
            {-2147483647 - 1, 0, 0, 24, 1, 86400, 1, -67768040609654340LL, -1},
            {-2147483647 - 1, 0, 0, 24, 1, 86400, 0, -67768040609654340LL, -67768040609654340LL},
            {-2147483647 - 1, 0, 1, 0, 0, 3600, 1, -67768040609737200LL, -1},
            {-2147483647 - 1, 0, 1, 1, 0, 0, 1, -67768040609737200LL, -67768040609740800LL},
            {-2147483647 - 1, 0, 1, 0, 0, 0, 1, -67768040609740800LL, -1},
            {-2147483647 - 1, 0, 1, 0, 0, 0, 0, -67768040609740800LL, -67768040609740800LL},
        };
        for (unsigned i = 0; i < sizeof ed / sizeof ed[0]; i++) {
            for (int pass = 0; pass < 2; pass++) {
                memset(&t, 0, sizeof t);
                t.tm_year = ed[i].y; t.tm_mon = ed[i].mo; t.tm_mday = ed[i].d; t.tm_hour = ed[i].h;
                t.tm_min = ed[i].mi; t.tm_sec = ed[i].sec; t.tm_isdst = ed[i].dst;
                errno_slot = 0;
                long long want = pass ? ed[i].mk : ed[i].tg;
                time_t r = pass ? mktime(&t) : timegm(&t);
                assert((long long)r == want);
                assert(errno_slot == (want == -1 ? EOVERFLOW : 0));
            }
        }
    }

    /* asctime / ctime and the _r forms (measured with glibc; the _r forms write at most 26 bytes). */
    {
        char b[64];
        struct tm a;
        memset(&a, 0, sizeof a);
        a.tm_year = 123; a.tm_mon = 10; a.tm_mday = 14; a.tm_hour = 22; a.tm_min = 13; a.tm_sec = 20; a.tm_wday = 2;
        assert(strcmp(asctime(&a), "Tue Nov 14 22:13:20 2023\n") == 0);
        assert(asctime_r(&a, b) == b && strcmp(b, "Tue Nov 14 22:13:20 2023\n") == 0);
        assert(asctime(&a) == asctime(&a)); /* one static buffer */
        /* Names out of range are "???"; numbers are %3d / %.2d, so negatives keep their sign. */
        struct { int wd, mo, d, h, mi, s, y; const char *want; } c[] = {
            {0, 0, 1, 0, 0, 0, 70, "Sun Jan  1 00:00:00 1970\n"},
            {9, 15, 5, 7, 4, 9, 124, "??? ???  5 07:04:09 2024\n"},
            {-1, -1, 100, 100, 100, 100, 100, "??? ???100 100:100:100 2000\n"},
            {3, 5, 5, 5, 5, 5, -1900, "Wed Jun  5 05:05:05 0\n"},
            {3, 5, 5, 5, 5, 5, -1901, "Wed Jun  5 05:05:05 -1\n"},
            {3, 5, 5, 5, 5, 5, 8100, "Wed Jun  5 05:05:05 10000\n"},
            {3, 5, -5, -5, -5, -5, 100, "Wed Jun -5 -05:-05:-05 2000\n"},
            {3, 5, 12345, 12345, 12345, 12345, 100, "Wed Jun12345 12345:12345:12345 2000\n"},
            {3, 5, 5, 5, 5, 5, -2147483647 - 1, "Wed Jun  5 05:05:05 -2147481748\n"},
        };
        for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
            memset(&a, 0, sizeof a);
            a.tm_wday = c[i].wd; a.tm_mon = c[i].mo; a.tm_mday = c[i].d; a.tm_hour = c[i].h; a.tm_min = c[i].mi;
            a.tm_sec = c[i].s; a.tm_year = c[i].y;
            assert(strcmp(asctime(&a), c[i].want) == 0);
        }
        /* The widest and narrowest texts still fit the static buffer. */
        memset(&a, 0, sizeof a);
        a.tm_mday = 2147483647; a.tm_hour = 2147483647; a.tm_min = 2147483647; a.tm_sec = 2147483647; a.tm_year = 2147483647 - 1900;
        assert(strcmp(asctime(&a), "Sun Jan2147483647 2147483647:2147483647:2147483647 2147483647\n") == 0);
        memset(&a, 0, sizeof a);
        a.tm_mday = -2147483647 - 1; a.tm_hour = -2147483647 - 1; a.tm_min = -2147483647 - 1; a.tm_sec = -2147483647 - 1;
        a.tm_year = -2147483647 - 1;
        assert(strcmp(asctime(&a), "Sun Jan-2147483648 -2147483648:-2147483648:-2147483648 -2147481748\n") == 0);
        /* tm_year above INT_MAX - 1900 would overflow the printed year: EOVERFLOW, nothing written. */
        memset(&a, 0, sizeof a);
        a.tm_year = 2147483647 - 1899;
        errno_slot = 0;
        assert(asctime(&a) == (char *)0 && errno_slot == EOVERFLOW);
        memset(b, '#', sizeof b); errno_slot = 0;
        assert(asctime_r(&a, b) == (char *)0 && errno_slot == EOVERFLOW && b[0] == '#');
        /* A NULL tm is EINVAL (this is what makes ctime of an unrepresentable time EINVAL, not EOVERFLOW). */
        errno_slot = 0;
        assert(asctime((const struct tm *)0) == (char *)0 && errno_slot == EINVAL);
        errno_slot = 0;
        assert(asctime_r((const struct tm *)0, b) == (char *)0 && errno_slot == EINVAL);
        /* asctime_r uses 26 bytes at most: a text of 26 characters or more does not fit, the buffer holds the first 25
         * characters and a NUL, and the result is NULL / EOVERFLOW. */
        memset(&a, 0, sizeof a); a.tm_year = 8100; a.tm_mday = 1;
        memset(b, '#', sizeof b); errno_slot = 0;
        assert(asctime_r(&a, b) == (char *)0 && errno_slot == EOVERFLOW);
        assert(strcmp(b, "Sun Jan  1 00:00:00 10000") == 0 && b[26] == '#');
        memset(&a, 0, sizeof a); a.tm_year = 2147483647 - 1900; a.tm_mday = 1;
        memset(b, '#', sizeof b); errno_slot = 0;
        assert(asctime_r(&a, b) == (char *)0 && errno_slot == EOVERFLOW && strcmp(b, "Sun Jan  1 00:00:00 21474") == 0);
        memset(&a, 0, sizeof a); a.tm_year = 8099; a.tm_mday = 1;
        assert(asctime_r(&a, b) == b && strcmp(b, "Sun Jan  1 00:00:00 9999\n") == 0);

        /* ctime: localtime then asctime. */
        time_t v = 1700000000;
        assert(strcmp(ctime(&v), "Tue Nov 14 22:13:20 2023\n") == 0);
        assert(ctime_r(&v, b) == b && strcmp(b, "Tue Nov 14 22:13:20 2023\n") == 0);
        v = -1;           assert(strcmp(ctime(&v), "Wed Dec 31 23:59:59 1969\n") == 0);
        v = 253402300799L; assert(strcmp(ctime(&v), "Fri Dec 31 23:59:59 9999\n") == 0);
        assert(ctime_r(&v, b) == b && strcmp(b, "Fri Dec 31 23:59:59 9999\n") == 0);
        v = 253402300800L; assert(strcmp(ctime(&v), "Sat Jan  1 00:00:00 10000\n") == 0);
        errno_slot = 0;   assert(ctime_r(&v, b) == (char *)0 && errno_slot == EOVERFLOW); /* 26 characters: too long for _r */
        v = -62135596800L; assert(strcmp(ctime(&v), "Mon Jan  1 00:00:00 1\n") == 0);
        v = -62135596801L; assert(strcmp(ctime(&v), "Sun Dec 31 23:59:59 0\n") == 0);
        v = -70000000000L; assert(strcmp(ctime(&v), "Fri Oct 15 19:33:20 -249\n") == 0);
        assert(ctime_r(&v, b) == b && strcmp(b, "Fri Oct 15 19:33:20 -249\n") == 0);
        /* A time that cannot be broken down is EINVAL (localtime's EOVERFLOW is replaced by asctime(NULL)'s EINVAL). */
        v = (time_t)1 << 62;  errno_slot = 0; assert(ctime(&v) == (char *)0 && errno_slot == EINVAL);
        errno_slot = 0;       assert(ctime_r(&v, b) == (char *)0 && errno_slot == EINVAL);
        v = -((time_t)1 << 62); errno_slot = 0; assert(ctime(&v) == (char *)0 && errno_slot == EINVAL);
        v = 67768036191676800L; errno_slot = 0; assert(ctime(&v) == (char *)0 && errno_slot == EINVAL);
        v = -67768040609740801L; errno_slot = 0; assert(ctime(&v) == (char *)0 && errno_slot == EINVAL);
        /* A representable time whose text is not: EOVERFLOW (the year is past what asctime can print). */
        v = 67768036191676799L; errno_slot = 0; assert(ctime(&v) == (char *)0 && errno_slot == EOVERFLOW);
        errno_slot = 0;         assert(ctime_r(&v, b) == (char *)0 && errno_slot == EOVERFLOW);
        v = 67768036160140800L; errno_slot = 0; assert(ctime(&v) == (char *)0 && errno_slot == EOVERFLOW);
        /* The first representable second: ctime prints it (static buffer), ctime_r cannot (the text is too long). */
        v = -67768040609740800L;
        assert(ctime(&v) != (char *)0);
        errno_slot = 0; assert(ctime_r(&v, b) == (char *)0 && errno_slot == EOVERFLOW);
        /* ctime and asctime(gmtime) share one static buffer. */
        v = 0;
        { char *c1 = ctime(&v); struct tm *g = gmtime(&v); assert(asctime(g) == c1); }
    }
    assert(difftime(10, 3) == 7.0 && difftime(3, 10) == -7.0);

    /* strftime, C locale: every conversion on 2023-11-14 22:13:20 UTC (a Tuesday). */
    memset(&t, 0, sizeof t);
    v = 1700000000; gmtime_r(&v, &t);
    struct tm T = t;
    EXPECT("%a", "Tue"); EXPECT("%A", "Tuesday"); EXPECT("%b", "Nov"); EXPECT("%B", "November");
    EXPECT("%c", "Tue Nov 14 22:13:20 2023"); EXPECT("%C", "20"); EXPECT("%d", "14"); EXPECT("%D", "11/14/23");
    EXPECT("%e", "14"); EXPECT("%F", "2023-11-14"); EXPECT("%g", "23"); EXPECT("%G", "2023"); EXPECT("%h", "Nov");
    EXPECT("%H", "22"); EXPECT("%I", "10"); EXPECT("%j", "318"); EXPECT("%k", "22"); EXPECT("%l", "10");
    EXPECT("%m", "11"); EXPECT("%M", "13"); EXPECT("%n", "\n"); EXPECT("%p", "PM"); EXPECT("%P", "pm");
    EXPECT("%r", "10:13:20 PM"); EXPECT("%R", "22:13"); EXPECT("%s", "1700000000"); EXPECT("%S", "20");
    EXPECT("%t", "\t"); EXPECT("%T", "22:13:20"); EXPECT("%u", "2"); EXPECT("%U", "46"); EXPECT("%V", "46");
    EXPECT("%w", "2"); EXPECT("%W", "46"); EXPECT("%x", "11/14/23"); EXPECT("%X", "22:13:20"); EXPECT("%y", "23");
    EXPECT("%Y", "2023"); EXPECT("%z", "+0000"); EXPECT("%Z", "GMT"); EXPECT("%%", "%");
    /* Unknown conversions and a trailing % are copied through as written. */
    EXPECT("%q", "%q"); EXPECT("%", "%"); EXPECT("abc", "abc"); EXPECT("%i", "%i"); EXPECT("%+", "%+"); EXPECT("%J", "%J");
    EXPECT("", "");
    /* E and O modifiers: valid combinations behave like the plain conversion; invalid ones are copied through. */
    EXPECT("%Ey", "23"); EXPECT("%Od", "14"); EXPECT("%Ec", "Tue Nov 14 22:13:20 2023"); EXPECT("%EY", "2023");
    EXPECT("%Ex", "11/14/23"); EXPECT("%EX", "22:13:20"); EXPECT("%EC", "20"); EXPECT("%Oe", "14"); EXPECT("%OH", "22");
    EXPECT("%OI", "10"); EXPECT("%Om", "11"); EXPECT("%OM", "13"); EXPECT("%OS", "20"); EXPECT("%Ou", "2");
    EXPECT("%OU", "46"); EXPECT("%OV", "46"); EXPECT("%Ow", "2"); EXPECT("%OW", "46"); EXPECT("%Oy", "23");
    EXPECT("%Ez", "+0000"); EXPECT("%Oz", "+0000"); EXPECT("%EZ", "GMT");
    EXPECT("%Ed", "%Ed"); EXPECT("%OY", "%OY"); EXPECT("%EO", "%EO"); EXPECT("%OE", "%OE"); EXPECT("%E%", "%");
    EXPECT("%O%", "%"); EXPECT("%Eq", "%Eq"); EXPECT("%E", "%E");
    /* Flags and widths. */
    EXPECT("%-d", "14"); EXPECT("%_d", "14"); EXPECT("%^a", "TUE"); EXPECT("%#a", "TUE"); EXPECT("%5d", "00014");
    EXPECT("%05d", "00014"); EXPECT("%10Y", "0000002023"); EXPECT("%3H", "022"); EXPECT("%-j", "318"); EXPECT("%^B", "NOVEMBER");
    EXPECT("%-H:%M", "22:13"); EXPECT(":%z", ":+0000"); EXPECT("%:z", "%:z");

    /* Padding on single-digit values (2024-03-05 07:04:09, a Tuesday). */
    memset(&t, 0, sizeof t); t.tm_year = 124; t.tm_mon = 2; t.tm_mday = 5; t.tm_hour = 7; t.tm_min = 4; t.tm_sec = 9;
    v = timegm(&t); gmtime_r(&v, &t); T = t;
    EXPECT("%d", "05"); EXPECT("%-d", "5"); EXPECT("%_d", " 5"); EXPECT("%0d", "05"); EXPECT("%e", " 5"); EXPECT("%-e", "5");
    EXPECT("%_e", " 5"); EXPECT("%0e", "05"); EXPECT("%H", "07"); EXPECT("%-H", "7"); EXPECT("%_H", " 7"); EXPECT("%k", " 7");
    EXPECT("%-k", "7"); EXPECT("%0k", "07"); EXPECT("%l", " 7"); EXPECT("%-l", "7"); EXPECT("%0l", "07"); EXPECT("%I", "07");
    EXPECT("%-I", "7"); EXPECT("%_I", " 7"); EXPECT("%j", "065"); EXPECT("%-j", "65"); EXPECT("%_j", " 65"); EXPECT("%m", "03");
    EXPECT("%-m", "3"); EXPECT("%_m", " 3"); EXPECT("%M", "04"); EXPECT("%-M", "4"); EXPECT("%S", "09"); EXPECT("%-S", "9");
    EXPECT("%y", "24"); EXPECT("%-y", "24"); EXPECT("%_y", "24"); EXPECT("%U", "09"); EXPECT("%-U", "9"); EXPECT("%C", "20");
    EXPECT("%-C", "20"); EXPECT("%Y", "2024"); EXPECT("%-Y", "2024"); EXPECT("%_Y", "2024"); EXPECT("%0Y", "2024");
    EXPECT("%6Y", "002024"); EXPECT("%_6Y", "  2024"); EXPECT("%-6Y", "  2024"); EXPECT("%8d", "00000005");
    EXPECT("%_8d", "       5"); EXPECT("%-8d", "       5"); EXPECT("%8e", "       5"); EXPECT("%8a", "     Tue");
    EXPECT("%_8a", "     Tue"); EXPECT("%-8a", "     Tue"); EXPECT("%8A", " Tuesday"); EXPECT("%^8A", " TUESDAY");
    EXPECT("%08A", "0Tuesday"); EXPECT("%10b", "       Mar"); EXPECT("%p", "AM"); EXPECT("%^p", "AM"); EXPECT("%#p", "am");
    EXPECT("%#P", "am"); EXPECT("%^P", "am"); EXPECT("%5p", "   AM"); EXPECT("%#A", "TUESDAY"); EXPECT("%#b", "MAR");
    EXPECT("%#B", "MARCH"); EXPECT("%^b", "MAR"); EXPECT("%#h", "MAR"); EXPECT("%#Z", "gmt"); EXPECT("%#c", "Tue Mar  5 07:04:09 2024");
    EXPECT("%^c", "TUE MAR  5 07:04:09 2024"); EXPECT("%^x", "03/05/24"); EXPECT("%#X", "07:04:09"); EXPECT("%10T", "  07:04:09");
    EXPECT("%8F", "2024-03-05"); EXPECT("%-F", "2024-03-05"); EXPECT("%_F", "2024-03-05"); EXPECT("%12c", "Tue Mar  5 07:04:09 2024");
    EXPECT("%5n", "    \n"); EXPECT("%5%", "    %"); EXPECT("%-%", "%"); EXPECT("%^%", "%"); EXPECT("%_5%", "    %");
    EXPECT("%5", "   %5"); EXPECT("%5E", "  %5E"); EXPECT("%-E", "%-E"); EXPECT("%-5d", "    5"); EXPECT("%_-d", "5");
    EXPECT("%0_d", " 5"); EXPECT("%^_a", "TUE"); EXPECT("%-^a", "TUE"); EXPECT("%#^a", "TUE");
    EXPECT("%1", "%1"); EXPECT("%-", "%-"); EXPECT("%_", "%_"); EXPECT("%^", "%^"); EXPECT("%#", "%#"); EXPECT("%0", "%0");

    /* Names for every weekday and month, and week numbers (2023-01-01 is a Sunday). */
    {
        static const char *const days[7] = {"Sun Sunday 7 0 01 00 52 2022 22 001  1", "Mon Monday 1 1 01 01 01 2023 23 002  2",
                                            "Tue Tuesday 2 2 01 01 01 2023 23 003  3", "Wed Wednesday 3 3 01 01 01 2023 23 004  4",
                                            "Thu Thursday 4 4 01 01 01 2023 23 005  5", "Fri Friday 5 5 01 01 01 2023 23 006  6",
                                            "Sat Saturday 6 6 01 01 01 2023 23 007  7"};
        for (int d = 0; d < 7; d++) {
            memset(&t, 0, sizeof t); t.tm_year = 123; t.tm_mday = 1 + d; timegm(&t); T = t;
            EXPECT("%a %A %u %w %U %W %V %G %g %j %e", days[d]);
        }
        static const char *const months[12] = {"Jan January Jan 01", "Feb February Feb 02", "Mar March Mar 03", "Apr April Apr 04",
                                               "May May May 05", "Jun June Jun 06", "Jul July Jul 07", "Aug August Aug 08",
                                               "Sep September Sep 09", "Oct October Oct 10", "Nov November Nov 11", "Dec December Dec 12"};
        for (int mo = 0; mo < 12; mo++) {
            memset(&t, 0, sizeof t); t.tm_year = 123; t.tm_mon = mo; t.tm_mday = 15; timegm(&t); T = t;
            EXPECT("%b %B %h %m", months[mo]);
        }
        /* ISO 8601 week edge cases (%G %V %u %g) with %U and %W. */
        struct { int y, mo, d; const char *want; } w[] = {
            {2020, 12, 31, "2020-W53-4 20 52 52"}, {2021, 1, 1, "2020-W53-5 20 00 00"}, {2021, 1, 3, "2020-W53-7 20 01 00"},
            {2021, 1, 4, "2021-W01-1 21 01 01"},   {2018, 12, 31, "2019-W01-1 19 52 53"}, {2019, 12, 30, "2020-W01-1 20 52 52"},
            {2016, 1, 3, "2015-W53-7 15 01 00"},   {2015, 12, 31, "2015-W53-4 15 52 52"}, {2024, 12, 30, "2025-W01-1 25 52 53"},
            {2026, 1, 1, "2026-W01-4 26 00 00"},
        };
        for (unsigned i = 0; i < sizeof w / sizeof w[0]; i++) {
            memset(&t, 0, sizeof t); t.tm_year = w[i].y - 1900; t.tm_mon = w[i].mo - 1; t.tm_mday = w[i].d; timegm(&t); T = t;
            EXPECT("%G-W%V-%u %g %U %W", w[i].want);
        }
    }

    /* Buffer sizes: the result plus its NUL must fit, else 0 (and the contents are unspecified). */
    memset(&t, 0, sizeof t); v = 1700000000; gmtime_r(&v, &t); T = t;
    {
        char c[16];
        assert(strftime(c, 11, "%Y-%m-%d", &T) == 10 && strcmp(c, "2023-11-14") == 0);
        assert(strftime(c, 10, "%Y-%m-%d", &T) == 0);
        assert(strftime(c, 9, "%Y-%m-%d", &T) == 0);
        assert(strftime(c, 0, "%Y", &T) == 0);
        assert(strftime(c, 1, "", &T) == 0 && c[0] == '\0');
        assert(strftime(c, 5, "%Y", &T) == 4 && strcmp(c, "2023") == 0);
        assert(strftime(c, 4, "%Y", &T) == 0);
    }
    {
        char c[17];
        assert(strftime(c, 17, "%A %B", &T) == 16 && strcmp(c, "Tuesday November") == 0);
        assert(strftime(c, 16, "%A %B", &T) == 0);
    }

    /* Out-of-range fields print '?' for names (never an out-of-bounds read) and the glibc forms for numbers. */
    {
        struct tm o; char b[64];
        memset(&o, 0, sizeof o); o.tm_wday = 9; o.tm_mon = 15;
        assert(fmt(b, sizeof b, "%a %A %b %B", &o) == 7 && strcmp(b, "? ? ? ?") == 0);
        o.tm_wday = -1; o.tm_mon = -1;
        assert(fmt(b, sizeof b, "%a %A %b %B", &o) == 7 && strcmp(b, "? ? ? ?") == 0);
        memset(&o, 0, sizeof o); o.tm_hour = 0;  assert(fmt(b, sizeof b, "%I|%l|%p|%P", &o) && strcmp(b, "12|12|AM|am") == 0);
        o.tm_hour = 12; assert(fmt(b, sizeof b, "%I|%l|%p|%P", &o) && strcmp(b, "12|12|PM|pm") == 0);
        o.tm_hour = 13; assert(fmt(b, sizeof b, "%I|%l|%p|%P", &o) && strcmp(b, "01| 1|PM|pm") == 0);
        memset(&o, 0, sizeof o); o.tm_hour = -1; assert(fmt(b, sizeof b, "%I|%l|%p|%P|%H", &o) && strcmp(b, "-1|-1|AM|am|-1") == 0);
        memset(&o, 0, sizeof o); o.tm_hour = 25; assert(fmt(b, sizeof b, "%I|%l|%p|%P|%H", &o) && strcmp(b, "13|13|PM|pm|25") == 0);
        memset(&o, 0, sizeof o); o.tm_hour = -3; o.tm_min = -4; o.tm_sec = -5; o.tm_mday = -6; o.tm_yday = -7;
        assert(fmt(b, sizeof b, "%H|%k|%M|%S|%d|%e|%j|%5H|%_5H|%-5H", &o) &&
               strcmp(b, "-3|-3|-4|-5|-6|-6|-06|-0003|   -3|   -3") == 0);
    }

    /* Years that are negative, tiny or have five digits (%C is the floor division by 100, %y is the modulo). */
    {
        struct tm o; char b[160];
        memset(&o, 0, sizeof o); o.tm_year = -1900 - 5; o.tm_mday = 1;
        assert(fmt(b, sizeof b, "%Y|%6Y|%_6Y|%-6Y|%06Y|%C|%4C|%y|%G|%g|%F|%D|%x|%c", &o) &&
               strcmp(b, "-5|-00005|    -5|    -5|-00005|-1|-001|95|-6|94|-5-01-01|01/01/95|01/01/95|Sun Jan  1 00:00:00 -5") == 0);
        memset(&o, 0, sizeof o); o.tm_year = 5 - 1900; o.tm_mday = 1;
        assert(fmt(b, sizeof b, "%Y|%6Y|%_6Y|%-6Y|%06Y|%C|%4C|%y|%G|%g|%F|%D|%x|%c", &o) &&
               strcmp(b, "5|000005|     5|     5|000005|0|0000|05|4|04|5-01-01|01/01/05|01/01/05|Sun Jan  1 00:00:00 5") == 0);
        memset(&o, 0, sizeof o); o.tm_year = -1; o.tm_mday = 1;
        assert(fmt(b, sizeof b, "%Y|%C|%y|%G|%g|%F", &o) && strcmp(b, "1899|18|99|1898|98|1899-01-01") == 0);
        memset(&o, 0, sizeof o); o.tm_year = 8100; o.tm_mday = 1;
        assert(fmt(b, sizeof b, "%Y|%6Y|%_6Y|%C|%4C|%y|%G|%g|%F|%D|%c", &o) &&
               strcmp(b, "10000|010000| 10000|100|0100|00|9999|99|10000-01-01|01/01/00|Sun Jan  1 00:00:00 10000") == 0);
    }

    /* %z: sign, hours and minutes from tm_gmtoff (seconds are dropped toward zero); %Z is tm_zone, or UTC without one. */
    {
        struct { long off; const char *want; } z[] = {
            {0, "+0000|     +000000|+0|+   0|+0000"},       {3600, "+0100|     +000100|+100|+ 100|+0100"},
            {-3600, "-0100|     -000100|-100|- 100|-0100"}, {5400, "+0130|     +000130|+130|+ 130|+0130"},
            {-5400, "-0130|     -000130|-130|- 130|-0130"}, {59, "+0000|     +000000|+0|+   0|+0000"},
            {-59, "-0000|     -000000|-0|-   0|-0000"},     {86399, "+2359|     +002359|+2359|+2359|+2359"},
            {-86399, "-2359|     -002359|-2359|-2359|-2359"}, {359999, "+9959|     +009959|+9959|+9959|+9959"},
            {-359999, "-9959|     -009959|-9959|-9959|-9959"}, {1, "+0000|     +000000|+0|+   0|+0000"},
            {-1, "-0000|     -000000|-0|-   0|-0000"},       {3599, "+0059|     +000059|+59|+  59|+0059"},
            {3601, "+0100|     +000100|+100|+ 100|+0100"},
        };
        for (unsigned i = 0; i < sizeof z / sizeof z[0]; i++) {
            struct tm o; char b[96];
            memset(&o, 0, sizeof o); o.tm_gmtoff = z[i].off;
            assert(fmt(b, sizeof b, "%z|%6z|%-z|%_z|%Ez", &o) && strcmp(b, z[i].want) == 0);
        }
        struct tm o; char b[32];
        memset(&o, 0, sizeof o); o.tm_gmtoff = -5400; o.tm_zone = "XYZ";
        assert(fmt(b, sizeof b, "%z %Z", &o) && strcmp(b, "-0130 XYZ") == 0);
        o.tm_zone = NULL;
        assert(fmt(b, sizeof b, "%Z|", &o) && strcmp(b, "UTC|") == 0);
        /* %s goes through the calendar, ignoring tm_gmtoff (the local zone is UTC). */
        memset(&o, 0, sizeof o); o.tm_year = 100; o.tm_mday = 1; o.tm_gmtoff = 7200;
        assert(fmt(b, sizeof b, "%s", &o) && strcmp(b, "946684800") == 0);
        memset(&o, 0, sizeof o); o.tm_year = -1900 - 5;
        assert(fmt(b, sizeof b, "%s", &o) && strcmp(b, "-62325072000") == 0);
        memset(&o, 0, sizeof o); o.tm_year = 2147483647;
        assert(fmt(b, sizeof b, "%s", &o) && strcmp(b, "67768036160054400") == 0);
    }
    return 0;
}
