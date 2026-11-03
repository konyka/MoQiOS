/* hello203: strptime, asctime and ctime in the freestanding user build. The exhaustive comparison against glibc is a
 * host differential test (lib/moqi_libc/host_tests holds the measured table); this runs the same code on the target, and
 * round-trips strftime -> strptime -> timegm with the kernel's own clock. */
#include "../lib/moqi_libc/include/moqi_syscalls.h"
#include "../lib/moqi_libc/include/stdio.h"
#include "../lib/moqi_libc/include/unistd.h"
#include "../lib/moqi_libc/include/time.h"

static int failures;
static void check(int ok, const char *what) {
    print(ok ? "hello203:   ok   " : "hello203:   FAIL ");
    print(what);
    print("\n");
    if (!ok) failures++;
}

static int same(const char *a, const char *b) {
    if (!a || !b) return a == b;
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

int main(int argc, char **argv, char **envp) {
    (void)argc; (void)argv; (void)envp;
    print("hello203: libc strptime / asctime / ctime\n");

    struct tm t = { 0 };
    const char *end = strptime("2023-11-14 22:13:20", "%Y-%m-%d %H:%M:%S", &t);
    check(end != (char *)0 && *end == '\0' && t.tm_year == 123 && t.tm_mon == 10 && t.tm_mday == 14 && t.tm_hour == 22 &&
              t.tm_min == 13 && t.tm_sec == 20,
          "A: strptime parses an ISO date and time");
    check(t.tm_wday == 2 && t.tm_yday == 317, "A: and fills in the weekday (Tuesday) and day of year (317) from the date");
    t = (struct tm){ 0 };
    end = strptime("Tue Nov 14 22:13:20 2023", "%c", &t);
    check(end && *end == '\0' && t.tm_year == 123 && t.tm_mon == 10 && t.tm_mday == 14 && t.tm_hour == 22, "A: %c parses the asctime layout");
    t = (struct tm){ 0 };
    end = strptime("10:13:20 PM", "%r", &t);
    check(end && t.tm_hour == 22 && t.tm_min == 13 && t.tm_sec == 20, "A: %r parses a 12-hour time with PM");
    t = (struct tm){ 0 };
    end = strptime("12 AM", "%I %p", &t);
    check(end && t.tm_hour == 0, "A: 12 AM is hour 0");
    t = (struct tm){ 0 };
    end = strptime("1700000000", "%s", &t);
    check(end && t.tm_year == 123 && t.tm_mon == 10 && t.tm_mday == 14 && t.tm_hour == 22, "A: %s parses seconds since the epoch");
    t = (struct tm){ 0 };
    end = strptime("+0530", "%z", &t);
    check(end && t.tm_gmtoff == 19800, "A: %z parses +0530 as 19800 seconds");
    t = (struct tm){ 0 };
    end = strptime("2024-03-05T07:04:09Z", "%FT%TZ", &t);
    check(end && *end == '\0' && t.tm_year == 124 && t.tm_mon == 2 && t.tm_mday == 5 && t.tm_hour == 7, "A: a literal T and Z around %F and %T");

    t = (struct tm){ 0 };
    check(strptime("2023-13-01", "%Y-%m-%d", &t) == (char *)0, "B: month 13 does not match");
    check(strptime("32", "%d", &t) == (char *)0, "B: day 32 does not match");
    check(strptime("24", "%H", &t) == (char *)0, "B: hour 24 does not match");
    check(strptime("Tu", "%a", &t) == (char *)0, "B: a partial weekday name does not match");
    check(strptime("x", "y", &t) == (char *)0, "B: a literal mismatch does not match");
    end = strptime("Tuesday", "%a", &t);
    check(end && *end == '\0', "B: %a accepts the full name too");
    t = (struct tm){ 0 };
    end = strptime("14abc", "%d", &t);
    check(end && *end == 'a' && t.tm_mday == 14, "B: the return value points at the first unparsed character");
    t = (struct tm){ 0 };
    t.tm_year = 111; t.tm_mon = 6; t.tm_mday = 17; t.tm_hour = 13;
    check(strptime("7:xx", "%R", &t) == (char *)0 && t.tm_hour == 13, "B: a composite that fails leaves the struct untouched (not a partial %H)");

    char buf[64];
    t = (struct tm){ 0 };
    t.tm_year = 123; t.tm_mon = 10; t.tm_mday = 14; t.tm_hour = 22; t.tm_min = 13; t.tm_sec = 20; t.tm_wday = 2;
    check(same(asctime(&t), "Tue Nov 14 22:13:20 2023\n"), "C: asctime formats the classic 26-byte line");
    check(asctime_r(&t, buf) == buf && same(buf, "Tue Nov 14 22:13:20 2023\n"), "C: asctime_r writes the same into the caller's buffer");
    time_t v = 1700000000;
    check(same(ctime(&v), "Tue Nov 14 22:13:20 2023\n"), "C: ctime of 1700000000");
    check(ctime_r(&v, buf) == buf && same(buf, "Tue Nov 14 22:13:20 2023\n"), "C: ctime_r");
    v = (time_t)1 << 62;
    errno = 0;
    check(ctime(&v) == (char *)0 && errno == EINVAL, "C: ctime of an unrepresentable time is NULL / EINVAL");
    t = (struct tm){ 0 };
    t.tm_year = 8100; t.tm_mday = 1;
    errno = 0;
    check(asctime_r(&t, buf) == (char *)0 && errno == EOVERFLOW, "C: asctime_r of a 5-digit year does not fit 26 bytes: NULL / EOVERFLOW");
    check(asctime(&t) != (char *)0, "C: but the static asctime copes with it");

    /* Round trip with the kernel clock: strftime -> strptime -> timegm gives the same second back. */
    struct timespec now;
    check(clock_gettime(CLOCK_REALTIME, &now) == 0, "D: the kernel realtime clock reads");
    time_t kt = now.tv_sec;
    struct tm k;
    gmtime_r(&kt, &k);
    char text[64];
    size_t n = strftime(text, sizeof text, "%Y-%m-%d %H:%M:%S %z", &k);
    check(n == 25, "D: strftime formats the kernel time");
    struct tm back = { 0 };
    end = strptime(text, "%Y-%m-%d %H:%M:%S %z", &back);
    check(end && *end == '\0' && back.tm_gmtoff == 0, "D: strptime parses it back, with a zero offset");
    check(timegm(&back) == kt, "D: and timegm of the result is the kernel time again");
    char text2[64];
    n = strftime(text2, sizeof text2, "%a %b %e %H:%M:%S %Y", &k);
    struct tm back2 = { 0 };
    end = strptime(text2, "%a %b %e %H:%M:%S %Y", &back2);
    check(n > 0 && end && *end == '\0' && back2.tm_wday == k.tm_wday && back2.tm_yday == k.tm_yday, "D: the asctime-style layout round-trips, weekday and yday included");
    char text3[32];
    n = strftime(text3, sizeof text3, "%s", &k);
    struct tm back3 = { 0 };
    end = strptime(text3, "%s", &back3);
    check(n > 0 && end && timegm(&back3) == kt, "D: %s round-trips");

    print(failures == 0 ? "hello203: PASS\n" : "hello203: FAIL\n");
    return failures;
}
