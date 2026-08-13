#include <stdio.h>
#include <string.h>

#include "../../servers/init/spawn_report.h"

enum spawn_kind {
    SPAWN_HELLO2,
    SPAWN_TEST,
    SPAWN_QUIET,
    SPAWN_SERVICE,
    SPAWN_SHELL,
};

struct fixture {
    const long *results;
    int result_count;
    int result_index;
    char output[2048];
    char attempts[256];
    int waits;
};

static struct fixture fixture;

static void append(char *buffer, const char *text) {
    strcat(buffer, text);
}

static long fake_spawn(const char *name) {
    append(fixture.attempts, name);
    append(fixture.attempts, " ");
    return fixture.results[fixture.result_index++];
}

static void fake_wait(void) {
    fixture.waits++;
}

static void report_failure(const char *name) {
    append(fixture.output, "spawn failed ");
    append(fixture.output, name);
    append(fixture.output, "\n");
}

static void run_spawn(const char *name, enum spawn_kind kind) {
    if (!init_spawn_created(fake_spawn(name), name, report_failure)) return;

    if (kind == SPAWN_HELLO2) {
        append(fixture.output, "spawned hello2\n");
        fake_wait();
        append(fixture.output, "child exited\n");
    } else if (kind == SPAWN_TEST) {
        append(fixture.output, "spawned ");
        append(fixture.output, name);
        append(fixture.output, "\n");
        fake_wait();
        append(fixture.output, name);
        append(fixture.output, " done\n");
    } else if (kind == SPAWN_QUIET) {
        append(fixture.output, "spawned ");
        append(fixture.output, name);
        append(fixture.output, "\n");
        fake_wait();
    }
}

static void run_fixture(const long *results, int count) {
    memset(&fixture, 0, sizeof(fixture));
    fixture.results = results;
    fixture.result_count = count;
    run_spawn("hello2", SPAWN_HELLO2);
    run_spawn("hello3", SPAWN_TEST);
    run_spawn("hello13", SPAWN_QUIET);
    run_spawn("syslogd", SPAWN_SERVICE);
    run_spawn("devmgr", SPAWN_SERVICE);
    run_spawn("sh", SPAWN_SHELL);
}

static int assert_equal(const char *label, const char *actual, const char *expected) {
    if (strcmp(actual, expected) == 0) return 0;
    fprintf(stderr, "%s\nexpected:\n%sactual:\n%s", label, expected, actual);
    return 1;
}

static int assert_int(const char *label, int actual, int expected) {
    if (actual == expected) return 0;
    fprintf(stderr, "%s: expected %d, got %d\n", label, expected, actual);
    return 1;
}

static int test_success_preserves_markers_and_order(void) {
    static const long results[] = { 2, 3, 13, 14, 15, 16 };
    run_fixture(results, 6);
    return assert_equal("success output", fixture.output,
                        "spawned hello2\nchild exited\n"
                        "spawned hello3\nhello3 done\n"
                        "spawned hello13\n") ||
           assert_equal("success attempts", fixture.attempts,
                        "hello2 hello3 hello13 syslogd devmgr sh ") ||
           assert_int("success waits", fixture.waits, 3);
}

static int test_only_minus_one_is_creation_failure(void) {
    static const long results[] = { -2, 3, 13, 14, 15, 16 };
    run_fixture(results, 6);
    return assert_equal("non-minus-one output", fixture.output,
                        "spawned hello2\nchild exited\n"
                        "spawned hello3\nhello3 done\n"
                        "spawned hello13\n") ||
           assert_int("non-minus-one waits", fixture.waits, 3);
}

static int test_failure_at(int failure_index, const char *expected_output,
                           int expected_waits) {
    long results[] = { 2, 3, 13, 14, 15, 16 };
    results[failure_index] = -1;
    run_fixture(results, 6);
    return assert_equal("failure output", fixture.output, expected_output) ||
           assert_equal("continued attempts", fixture.attempts,
                        "hello2 hello3 hello13 syslogd devmgr sh ") ||
           assert_int("failure waits", fixture.waits, expected_waits);
}

int main(void) {
    int failed = test_success_preserves_markers_and_order();
    failed |= test_only_minus_one_is_creation_failure();
    failed |= test_failure_at(0,
        "spawn failed hello2\nspawned hello3\nhello3 done\nspawned hello13\n", 2);
    failed |= test_failure_at(1,
        "spawned hello2\nchild exited\nspawn failed hello3\nspawned hello13\n", 2);
    failed |= test_failure_at(2,
        "spawned hello2\nchild exited\nspawned hello3\nhello3 done\nspawn failed hello13\n", 2);
    failed |= test_failure_at(3,
        "spawned hello2\nchild exited\nspawned hello3\nhello3 done\nspawned hello13\nspawn failed syslogd\n", 3);
    failed |= test_failure_at(4,
        "spawned hello2\nchild exited\nspawned hello3\nhello3 done\nspawned hello13\nspawn failed devmgr\n", 3);
    failed |= test_failure_at(5,
        "spawned hello2\nchild exited\nspawned hello3\nhello3 done\nspawned hello13\nspawn failed sh\n", 3);
    return failed;
}
