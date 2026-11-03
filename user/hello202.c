/* hello202: the moqi_libc calendar (gmtime_r, timegm, mktime) and strftime in the freestanding user build, fed by the
 * real kernel clock. The exhaustive comparison against glibc runs on the host (lib/moqi_libc/host_tests); this checks
 * that the same code, built without a host libc and run on the target, gives the same answers, and that it agrees with
 * the kernel's own notion of the time. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello202:   ok   " : "hello202:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int same(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

static int fmt_is(const struct tm *t, const char *f, const char *want) {
    char b[128];
    size_t n = strftime(b, sizeof b, f, t);
    if (n == 0 && want[0] != '\0') return 0;
    return same(b, want);
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello202: libc calendar and strftime\n");

    struct tm t;
    time_t v = 1700000000;
    check(gmtime_r(&v, &t) == &t && t.tm_year == 123 && t.tm_mon == 10 && t.tm_mday == 14 && t.tm_hour == 22 &&
              t.tm_min == 13 && t.tm_sec == 20 && t.tm_wday == 2 && t.tm_yday == 317,
          "A: gmtime_r(1700000000) is Tuesday 2023-11-14 22:13:20, day 317");
    check(t.tm_isdst == 0 && t.tm_gmtoff == 0 && t.tm_zone != (const char *)0 && same(t.tm_zone, "GMT"), "A: zone GMT, offset 0, no DST");
    v = -1;
    check(gmtime_r(&v, &t) && t.tm_year == 69 && t.tm_mon == 11 && t.tm_mday == 31 && t.tm_sec == 59 && t.tm_wday == 3, "A: -1 is 1969-12-31 23:59:59, a Wednesday");
    v = 951782400;
    check(gmtime_r(&v, &t) && t.tm_mon == 1 && t.tm_mday == 29 && t.tm_yday == 59, "A: 2000-02-29 exists (century leap year)");
    v = 4107542400L;
    check(gmtime_r(&v, &t) && t.tm_mon == 2 && t.tm_mday == 1, "A: 2100 is not a leap year");
    v = (time_t)1 << 62;
    errno = 0;
    check(gmtime_r(&v, &t) == (struct tm *)0 && errno == EOVERFLOW, "A: a time too large for tm_year is NULL / EOVERFLOW");

    struct tm n = { 0 };
    n.tm_year = 100; n.tm_mon = 12; n.tm_mday = 32;
    check(timegm(&n) == 980985600L && n.tm_year == 101 && n.tm_mon == 1 && n.tm_mday == 1, "B: timegm normalises month 12 / day 32 to 2001-02-01");
    n = (struct tm){ 0 };
    n.tm_year = 70; n.tm_mday = 1; n.tm_sec = -1;
    errno = 0;
    check(timegm(&n) == -1 && errno == 0 && n.tm_year == 69 && n.tm_mon == 11 && n.tm_mday == 31 && n.tm_sec == 59,
          "B: second -1 on the epoch is the last second of 1969: a real -1 result, with errno untouched");
    n = (struct tm){ 0 };
    n.tm_year = 70; n.tm_sec = -1; /* tm_mday left 0: the day before the 1st, so this is Dec 30, not Dec 31 */
    check(timegm(&n) == -86401 && n.tm_mday == 30, "B: a zero tm_mday is the day before the 1st (-86401 here)");
    n = (struct tm){ 0 };
    n.tm_year = 2147483647; n.tm_mon = 12; n.tm_mday = 1;
    errno = 0;
    check(timegm(&n) == (time_t)-1 && errno == EOVERFLOW && n.tm_mon == 12, "B: a year that does not fit tm_year is -1 / EOVERFLOW and *tm keeps its fields");
    n = (struct tm){ 0 };
    n.tm_year = 100; n.tm_mday = 1; n.tm_hour = 5; n.tm_isdst = 1;
    check(mktime(&n) == 946699200L && n.tm_hour == 4 && n.tm_isdst == 0, "B: mktime with tm_isdst > 0 is an hour earlier, as glibc does with a UTC zone");
    n.tm_isdst = 0; n.tm_hour = 5;
    check(mktime(&n) == 946702800L, "B: and with tm_isdst 0 it is not");

    /* Round trip over a spread of times, including both sides of every leap day in 1900..2200. */
    int round_ok = 1;
    for (long long x = -2208988800LL; x < 7258118400LL; x += 86400LL * 37 + 4321) {
        time_t tx = (time_t)x;
        struct tm g;
        if (!gmtime_r(&tx, &g) || timegm(&g) != tx) { round_ok = 0; break; }
    }
    check(round_ok, "C: gmtime_r then timegm returns the same time over 1900..2200");

    struct tm q = { 0 };
    v = 1700000000; gmtime_r(&v, &q);
    check(fmt_is(&q, "%Y-%m-%d %H:%M:%S", "2023-11-14 22:13:20"), "D: strftime ISO date and time");
    check(fmt_is(&q, "%a, %d %b %Y %T %z", "Tue, 14 Nov 2023 22:13:20 +0000"), "D: strftime RFC 2822 style");
    check(fmt_is(&q, "%A %B %e %j %U %V %G", "Tuesday November 14 318 46 46 2023"), "D: names, day of year and week numbers");
    check(fmt_is(&q, "%c|%x|%X|%r", "Tue Nov 14 22:13:20 2023|11/14/23|22:13:20|10:13:20 PM"), "D: the composite conversions");
    check(fmt_is(&q, "%s", "1700000000") && fmt_is(&q, "%%|%n|%t", "%|\n|\t"), "D: %s, %%, %n, %t");
    check(fmt_is(&q, "%-d|%_d|%05d|%^a|%#b", "14|14|00014|TUE|NOV"), "D: flags and widths");
    check(fmt_is(&q, "%Ey %Od %Ex %q %", "23 14 11/14/23 %q %"), "D: E/O modifiers behave as plain; unknown conversions are echoed");
    char small[8];
    check(strftime(small, sizeof small, "%Y-%m-%d", &q) == 0, "D: a result that does not fit (10 chars into 8) is 0");
    check(strftime(small, 11, "%Y", &q) == 4, "D: and one that fits is its length");

    /* The kernel clock: its time_t breaks down to a plausible, internally consistent date. */
    struct timespec now;
    check(clock_gettime(CLOCK_REALTIME, &now) == 0, "E: the kernel realtime clock reads");
    struct tm k;
    time_t kt = now.tv_sec;
    check(gmtime_r(&kt, &k) && k.tm_year >= 120 && k.tm_mon >= 0 && k.tm_mon <= 11 && k.tm_mday >= 1 && k.tm_mday <= 31 &&
              k.tm_hour >= 0 && k.tm_hour <= 23 && k.tm_min >= 0 && k.tm_min <= 59 && k.tm_sec >= 0 && k.tm_sec <= 60,
          "E: gmtime_r of the kernel time gives a valid date in 2020 or later");
    check(timegm(&k) == kt, "E: and timegm gives the kernel time back");
    char today[32];
    check(strftime(today, sizeof today, "%F %T", &k) == 19 && today[4] == '-' && today[10] == ' ', "E: strftime formats it as YYYY-MM-DD HH:MM:SS");
    {
        char sec[24];
        size_t len = strftime(sec, sizeof sec, "%s", &k);
        long long parsed = 0;
        for (size_t i = 0; i < len; i++) parsed = parsed * 10 + (sec[i] - '0');
        check(len > 0 && parsed == (long long)kt, "E: %s of that date is the kernel time");
    }

    print(failures == 0 ? "hello202: PASS\n" : "hello202: FAIL\n");
    return failures;
}
