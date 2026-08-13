#include <stdio.h>
#include <string.h>

#include "../../servers/init/supervisor.h"

struct fixture {
    const long *spawn_results;
    int spawn_result_count;
    int spawn_result_index;
    int spawn_calls;
    int failure_reports;
    int disabled_reports;
    char attempts[256];
};

static struct fixture fixture;

static void reset_fixture(const long *results, int count) {
    memset(&fixture, 0, sizeof(fixture));
    fixture.spawn_results = results;
    fixture.spawn_result_count = count;
}

static long fake_spawn(const char *name) {
    size_t used = strlen(fixture.attempts);

    if (fixture.spawn_result_index >= fixture.spawn_result_count) return -1;
    snprintf(fixture.attempts + used, sizeof(fixture.attempts) - used,
             "%s ", name);
    fixture.spawn_calls++;
    return fixture.spawn_results[fixture.spawn_result_index++];
}

static void report_spawn_failure(const char *name) {
    (void)name;
    fixture.failure_reports++;
}

static void report_disabled(const char *name) {
    (void)name;
    fixture.disabled_reports++;
}

static const struct init_supervisor_ops ops = {
    fake_spawn,
    report_spawn_failure,
    report_disabled,
};

static int assert_long(const char *label, long actual, long expected) {
    if (actual == expected) return 0;
    fprintf(stderr, "%s: expected %ld, got %ld\n", label, expected, actual);
    return 1;
}

static int assert_string(const char *label, const char *actual,
                         const char *expected) {
    if (strcmp(actual, expected) == 0) return 0;
    fprintf(stderr, "%s: expected \"%s\", got \"%s\"\n",
            label, expected, actual);
    return 1;
}

static int register_service(struct init_supervisor *supervisor,
                            const char *name) {
    int slot = init_supervisor_register(supervisor, name);

    if (slot >= 0) return slot;
    fprintf(stderr, "failed to register %s\n", name);
    return 0;
}

static int test_initial_spawn_success(void) {
    static const long results[] = { 41 };
    struct init_supervisor supervisor;
    int slot;

    init_supervisor_init(&supervisor);
    slot = register_service(&supervisor, "syslogd");
    reset_fixture(results, 1);
    init_supervisor_start(&supervisor, slot, &ops);

    return assert_long("initial success state",
                       supervisor.services[slot].state,
                       INIT_SERVICE_RUNNING) ||
           assert_long("initial success tid",
                       supervisor.services[slot].tid, 41) ||
           assert_long("initial success restart count",
                       supervisor.services[slot].restarts_used, 0) ||
           assert_long("initial success calls", fixture.spawn_calls, 1) ||
           assert_long("initial success reports", fixture.failure_reports, 0);
}

static int test_initial_spawn_failure_retries(void) {
    static const long results[] = { -1, 42 };
    struct init_supervisor supervisor;
    int slot;

    init_supervisor_init(&supervisor);
    slot = register_service(&supervisor, "syslogd");
    reset_fixture(results, 2);
    init_supervisor_start(&supervisor, slot, &ops);

    return assert_long("initial failure state",
                       supervisor.services[slot].state,
                       INIT_SERVICE_RUNNING) ||
           assert_long("initial failure replacement tid",
                       supervisor.services[slot].tid, 42) ||
           assert_long("initial failure restart count",
                       supervisor.services[slot].restarts_used, 1) ||
           assert_long("initial failure calls", fixture.spawn_calls, 2) ||
           assert_long("initial failure reports", fixture.failure_reports, 1);
}

static int test_abnormal_exit_restarts_and_remaps_tid(void) {
    static const long results[] = { 51, 52 };
    struct init_supervisor supervisor;
    int slot;

    init_supervisor_init(&supervisor);
    slot = register_service(&supervisor, "devmgr");
    reset_fixture(results, 2);
    init_supervisor_start(&supervisor, slot, &ops);

    if (init_supervisor_child_exit(&supervisor, 51, 7, &ops) !=
        INIT_SUPERVISOR_RESTARTED) {
        fprintf(stderr, "abnormal exit did not report a restart\n");
        return 1;
    }

    return assert_long("abnormal exit state",
                       supervisor.services[slot].state,
                       INIT_SERVICE_RUNNING) ||
           assert_long("abnormal exit new tid",
                       supervisor.services[slot].tid, 52) ||
           assert_long("abnormal exit restart count",
                       supervisor.services[slot].restarts_used, 1) ||
           assert_string("abnormal exit identity", fixture.attempts,
                         "devmgr devmgr ");
}

static int test_normal_exit_does_not_restart(void) {
    static const long results[] = { 61 };
    struct init_supervisor supervisor;
    int slot;

    init_supervisor_init(&supervisor);
    slot = register_service(&supervisor, "syslogd");
    reset_fixture(results, 1);
    init_supervisor_start(&supervisor, slot, &ops);

    if (init_supervisor_child_exit(&supervisor, 61, 0, &ops) !=
        INIT_SUPERVISOR_CLEAN_STOP) {
        fprintf(stderr, "normal exit did not report a clean stop\n");
        return 1;
    }

    return assert_long("normal exit state",
                       supervisor.services[slot].state,
                       INIT_SERVICE_STOPPED) ||
           assert_long("normal exit tid", supervisor.services[slot].tid, -1) ||
           assert_long("normal exit calls", fixture.spawn_calls, 1) ||
           assert_long("normal exit restart count",
                       supervisor.services[slot].restarts_used, 0);
}

static int test_bounded_retry_exhaustion(void) {
    static const long results[] = { 71, -1, -1, -1 };
    struct init_supervisor supervisor;
    int slot;

    init_supervisor_init(&supervisor);
    slot = register_service(&supervisor, "devmgr");
    reset_fixture(results, 4);
    init_supervisor_start(&supervisor, slot, &ops);

    if (init_supervisor_child_exit(&supervisor, 71, 1, &ops) !=
        INIT_SUPERVISOR_DISABLED) {
        fprintf(stderr, "retry exhaustion did not report disabled\n");
        return 1;
    }

    return assert_long("exhausted state",
                       supervisor.services[slot].state,
                       INIT_SERVICE_DISABLED) ||
           assert_long("exhausted tid", supervisor.services[slot].tid, -1) ||
           assert_long("bounded calls", fixture.spawn_calls,
                       1 + INIT_SUPERVISOR_RESTART_BUDGET) ||
           assert_long("bounded restart count",
                       supervisor.services[slot].restarts_used,
                       INIT_SUPERVISOR_RESTART_BUDGET) ||
           assert_long("bounded failure reports", fixture.failure_reports,
                       INIT_SUPERVISOR_RESTART_BUDGET) ||
           assert_long("disabled reports", fixture.disabled_reports, 1);
}

static int test_unknown_child_is_ignored(void) {
    static const long results[] = { 81 };
    struct init_supervisor supervisor;
    int slot;

    init_supervisor_init(&supervisor);
    slot = register_service(&supervisor, "syslogd");
    reset_fixture(results, 1);
    init_supervisor_start(&supervisor, slot, &ops);

    if (init_supervisor_child_exit(&supervisor, 999, 9, &ops) !=
        INIT_SUPERVISOR_IGNORED) {
        fprintf(stderr, "unknown child was not ignored\n");
        return 1;
    }

    return assert_long("unknown child state",
                       supervisor.services[slot].state,
                       INIT_SERVICE_RUNNING) ||
           assert_long("unknown child tid", supervisor.services[slot].tid, 81) ||
           assert_long("unknown child calls", fixture.spawn_calls, 1);
}

static int test_fixed_table_capacity_and_identity(void) {
    static const long results[] = { 91, 92 };
    struct init_supervisor supervisor;
    int first;
    int second;

    init_supervisor_init(&supervisor);
    first = init_supervisor_register(&supervisor, "svc-a");
    second = init_supervisor_register(&supervisor, "svc-b");

    if (first != 0 || second != 1 ||
        init_supervisor_register(&supervisor, "svc-a") != -1 ||
        init_supervisor_register(&supervisor, "svc-c") != 2 ||
        init_supervisor_register(&supervisor, "svc-d") != 3 ||
        init_supervisor_register(&supervisor, "svc-e") != -1) {
        fprintf(stderr, "fixed-table registration identity/capacity failed\n");
        return 1;
    }

    reset_fixture(results, 2);
    init_supervisor_start(&supervisor, first, &ops);
    init_supervisor_start(&supervisor, second, &ops);

    if (init_supervisor_child_exit(&supervisor, 91, 0, &ops) !=
        INIT_SUPERVISOR_CLEAN_STOP) {
        fprintf(stderr, "first service identity lookup failed\n");
        return 1;
    }

    return assert_long("first identity state",
                       supervisor.services[first].state,
                       INIT_SERVICE_STOPPED) ||
           assert_long("second identity state",
                       supervisor.services[second].state,
                       INIT_SERVICE_RUNNING) ||
           assert_long("second identity tid",
                       supervisor.services[second].tid, 92);
}

int main(void) {
    int failed = test_initial_spawn_success();

    failed |= test_initial_spawn_failure_retries();
    failed |= test_abnormal_exit_restarts_and_remaps_tid();
    failed |= test_normal_exit_does_not_restart();
    failed |= test_bounded_retry_exhaustion();
    failed |= test_unknown_child_is_ignored();
    failed |= test_fixed_table_capacity_and_identity();
    return failed;
}
