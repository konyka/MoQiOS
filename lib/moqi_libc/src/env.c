/* env.c — setenv, unsetenv, putenv, clearenv over the process environ (see include/stdlib.h). getenv is in stdlib.c.
 *
 * The array that arrives with the process (on the initial stack) is never grown: the first insertion copies it into a
 * malloc'ed array that this file owns and doubles when full. Replacing and removing entries work in place, as glibc
 * does. Old arrays and replaced strings are not freed, because getenv walks environ without a lock and a returned
 * pointer must stay valid (glibc keeps its strings for the same reason); the leak is bounded by twice the final array
 * and by the strings a program replaced. */
#include "../include/errno.h"
#include "../include/stdlib.h"
#include "../include/string.h"
#include "../include/unistd.h"

static char **own_array;
static size_t own_cap;
static volatile char env_lock_word;

static void env_lock(void) {
    unsigned spins = 0;
    while (__atomic_test_and_set(&env_lock_word, __ATOMIC_ACQUIRE)) {
        if ((++spins & 63U) == 0) yield();
    }
}

static void env_unlock(void) { __atomic_clear(&env_lock_word, __ATOMIC_RELEASE); }

static size_t env_count(void) {
    size_t n = 0;
    if (environ) while (environ[n]) n++;
    return n;
}

static int entry_is(const char *entry, const char *name, size_t nlen) {
    return strncmp(entry, name, nlen) == 0 && entry[nlen] == '=';
}

static char **find_entry(const char *name, size_t nlen) {
    if (!environ) return (char **)0;
    for (char **e = environ; *e; e++)
        if (entry_is(*e, name, nlen)) return e;
    return (char **)0;
}

/* Makes environ an array this file owns with room for count entries plus one new entry and the terminator. */
static int ensure_room(size_t count) {
    size_t need = count + 2;
    if (environ && environ == own_array && own_cap >= need) return 0;
    if (!environ && own_array && own_cap >= need) {
        environ = own_array;
        return 0;
    }
    size_t cap = need * 2;
    if (cap < 16) cap = 16;
    if (cap > (size_t)-1 / sizeof(char *)) {
        errno = ENOMEM;
        return -1;
    }
    char **arr = (char **)malloc(cap * sizeof(char *));
    if (!arr) {
        errno = ENOMEM;
        return -1;
    }
    for (size_t i = 0; i < count; i++) arr[i] = environ[i];
    own_array = arr;
    own_cap = cap;
    environ = arr;
    return 0;
}

static int append_entry(char *entry) {
    size_t count = env_count();
    if (ensure_room(count) != 0) return -1;
    environ[count] = entry;
    environ[count + 1] = (char *)0;
    return 0;
}

static int valid_name(const char *name, size_t *len) {
    if (!name || name[0] == '\0') return 0;
    size_t n = 0;
    while (name[n]) {
        if (name[n] == '=') return 0;
        n++;
    }
    *len = n;
    return 1;
}

int setenv(const char *name, const char *value, int overwrite) {
    size_t nlen;
    if (!valid_name(name, &nlen) || !value) {
        errno = EINVAL;
        return -1;
    }
    size_t vlen = strlen(value);
    int rc = 0;
    env_lock();
    char **slot = find_entry(name, nlen);
    if (slot && !overwrite) goto out;
    if (slot && strncmp(*slot + nlen + 1, value, vlen + 1) == 0) goto out;
    if (vlen > (size_t)-1 - nlen - 2) {
        errno = ENOMEM;
        rc = -1;
        goto out;
    }
    char *entry = (char *)malloc(nlen + 1 + vlen + 1);
    if (!entry) {
        errno = ENOMEM;
        rc = -1;
        goto out;
    }
    memcpy(entry, name, nlen);
    entry[nlen] = '=';
    memcpy(entry + nlen + 1, value, vlen + 1);
    if (slot) {
        *slot = entry;
    } else if (append_entry(entry) != 0) {
        free(entry);
        rc = -1;
    }
out:
    env_unlock();
    return rc;
}

int unsetenv(const char *name) {
    size_t nlen;
    if (!valid_name(name, &nlen)) {
        errno = EINVAL;
        return -1;
    }
    env_lock();
    if (environ) {
        char **dst = environ;
        for (char **src = environ; *src; src++)
            if (!entry_is(*src, name, nlen)) *dst++ = *src;
        *dst = (char *)0;
    }
    env_unlock();
    return 0;
}

int putenv(char *string) {
    if (!string) {
        errno = EINVAL;
        return -1;
    }
    const char *eq = strchr(string, '=');
    if (!eq) {
        unsetenv(string);
        return 0;
    }
    size_t nlen = (size_t)(eq - string);
    int rc = 0;
    env_lock();
    char **slot = find_entry(string, nlen);
    if (slot) *slot = string;
    else if (append_entry(string) != 0) rc = -1;
    env_unlock();
    return rc;
}

int clearenv(void) {
    env_lock();
    environ = (char **)0;
    env_unlock();
    return 0;
}
