#ifndef MOQIOS_INIT_SUPERVISOR_H
#define MOQIOS_INIT_SUPERVISOR_H

#include "spawn_report.h"

/* The table is intentionally tiny: init only supervises explicitly listed
 * resident services, and each child lookup scans at most four entries. */
#define INIT_SUPERVISOR_CAPACITY 4
#define INIT_SUPERVISOR_RESTART_BUDGET 3

enum init_service_state {
    INIT_SERVICE_UNUSED,
    INIT_SERVICE_REGISTERED,
    INIT_SERVICE_RUNNING,
    INIT_SERVICE_STOPPED,
    INIT_SERVICE_DISABLED,
};

enum init_supervisor_result {
    INIT_SUPERVISOR_IGNORED,
    INIT_SUPERVISOR_RESTARTED,
    INIT_SUPERVISOR_CLEAN_STOP,
    INIT_SUPERVISOR_DISABLED,
};

typedef long (*init_supervisor_spawn)(const char *name);

struct init_supervisor_ops {
    init_supervisor_spawn spawn;
    init_spawn_failure_reporter report_spawn_failure;
    init_spawn_failure_reporter report_disabled;
};

struct init_supervisor_service {
    const char *name;
    long tid;
    unsigned int restarts_used;
    enum init_service_state state;
};

struct init_supervisor {
    struct init_supervisor_service services[INIT_SUPERVISOR_CAPACITY];
};

static int init_supervisor_name_equal(const char *left, const char *right) {
    if (left == right) return 1;
    if (left == (const char *)0 || right == (const char *)0) return 0;

    while (*left != '\0' && *left == *right) {
        left++;
        right++;
    }
    return *left == *right;
}

static int init_supervisor_valid_slot(int slot) {
    return slot >= 0 && slot < INIT_SUPERVISOR_CAPACITY;
}

static void init_supervisor_init(struct init_supervisor *supervisor) {
    int slot;

    for (slot = 0; slot < INIT_SUPERVISOR_CAPACITY; slot++) {
        supervisor->services[slot].name = (const char *)0;
        supervisor->services[slot].tid = -1;
        supervisor->services[slot].restarts_used = 0;
        supervisor->services[slot].state = INIT_SERVICE_UNUSED;
    }
}

static int init_supervisor_register(struct init_supervisor *supervisor,
                                    const char *name) {
    int slot;

    if (name == (const char *)0 || *name == '\0') return -1;

    for (slot = 0; slot < INIT_SUPERVISOR_CAPACITY; slot++) {
        if (supervisor->services[slot].state != INIT_SERVICE_UNUSED &&
            init_supervisor_name_equal(supervisor->services[slot].name, name)) {
            return -1;
        }
    }

    for (slot = 0; slot < INIT_SUPERVISOR_CAPACITY; slot++) {
        if (supervisor->services[slot].state == INIT_SERVICE_UNUSED) {
            supervisor->services[slot].name = name;
            supervisor->services[slot].tid = -1;
            supervisor->services[slot].restarts_used = 0;
            supervisor->services[slot].state = INIT_SERVICE_REGISTERED;
            return slot;
        }
    }
    return -1;
}

static void init_supervisor_disable(struct init_supervisor_service *service,
                                    const struct init_supervisor_ops *ops) {
    service->tid = -1;
    service->state = INIT_SERVICE_DISABLED;
    if (ops->report_disabled != (init_spawn_failure_reporter)0) {
        ops->report_disabled(service->name);
    }
}

static int init_supervisor_spawn_until_running(
    struct init_supervisor_service *service,
    const struct init_supervisor_ops *ops, int first_attempt_is_restart) {
    long tid;
    int is_restart = first_attempt_is_restart;

    for (;;) {
        if (is_restart) {
            if (service->restarts_used >= INIT_SUPERVISOR_RESTART_BUDGET) {
                init_supervisor_disable(service, ops);
                return 0;
            }
            service->restarts_used++;
        }
        tid = ops->spawn(service->name);
        if (init_spawn_created(tid, service->name,
                               ops->report_spawn_failure)) {
            service->tid = tid;
            service->state = INIT_SERVICE_RUNNING;
            return 1;
        }
        is_restart = 1;
    }
}

static void init_supervisor_start(struct init_supervisor *supervisor, int slot,
                                  const struct init_supervisor_ops *ops) {
    struct init_supervisor_service *service;

    if (!init_supervisor_valid_slot(slot)) return;
    service = &supervisor->services[slot];
    if (service->state != INIT_SERVICE_REGISTERED) return;
    (void)init_supervisor_spawn_until_running(service, ops, 0);
}

static int init_supervisor_find_tid(const struct init_supervisor *supervisor,
                                    long tid) {
    int slot;

    for (slot = 0; slot < INIT_SUPERVISOR_CAPACITY; slot++) {
        if (supervisor->services[slot].state == INIT_SERVICE_RUNNING &&
            supervisor->services[slot].tid == tid) {
            return slot;
        }
    }
    return -1;
}

static enum init_supervisor_result init_supervisor_child_exit(
    struct init_supervisor *supervisor, long tid, int status,
    const struct init_supervisor_ops *ops) {
    int slot = init_supervisor_find_tid(supervisor, tid);
    struct init_supervisor_service *service;

    if (slot < 0) return INIT_SUPERVISOR_IGNORED;
    service = &supervisor->services[slot];
    service->tid = -1;
    if (status == 0) {
        service->state = INIT_SERVICE_STOPPED;
        return INIT_SUPERVISOR_CLEAN_STOP;
    }

    if (init_supervisor_spawn_until_running(service, ops, 1)) {
        return INIT_SUPERVISOR_RESTARTED;
    }
    return INIT_SUPERVISOR_DISABLED;
}

#endif
