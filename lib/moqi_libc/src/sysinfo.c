/* sysinfo.c -- uname, gethostname, getrandom, getentropy, getpagesize and sysconf (see include/utsname.h, include/sysinfo.h). */
#include <string.h>

#include "../include/sysinfo.h"
#include "../include/utsname.h"
#include "hostsys.h"

int uname(struct utsname *buf) { return __moqi_ret(MSYS1(SYS_uname, buf)); }

int gethostname(char *name, size_t size) {
    struct utsname u;
    if (uname(&u) != 0) return -1;
    size_t len = strlen(u.nodename);
    if (size < len + 1) {
        if (size > 0) memcpy(name, u.nodename, size);
        errno = ENAMETOOLONG;
        return -1;
    }
    memcpy(name, u.nodename, len + 1);
    return 0;
}

long getrandom(void *buf, size_t size, unsigned int flags) {
    long r = MSYS3(SYS_getrandom, buf, size, flags);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    return r;
}

/* All or nothing: a short read is continued; the 256-byte limit is checked before the kernel is asked. */
int getentropy(void *buf, size_t size) {
    if (size > 256) {
        errno = EIO;
        return -1;
    }
    unsigned char *p = (unsigned char *)buf;
    while (size > 0) {
        long r = getrandom(p, size, 0);
        if (r < 0) return -1;
        if (r == 0) {
            errno = EIO;
            return -1;
        }
        p += r;
        size -= (size_t)r;
    }
    return 0;
}

int getpagesize(void) { return 4096; }

/* The number of set bits in the affinity mask the kernel reports for this process; one CPU when the kernel refuses. */
static long cpu_count(void) {
    unsigned char mask[128];
    memset(mask, 0, sizeof mask);
    long r = MSYS3(SYS_sched_getaffinity, 0, sizeof mask, mask);
    if (__moqi_is_error(r) || r <= 0) return 1;
    long n = 0;
    for (long i = 0; i < r && i < (long)sizeof mask; i++) {
        for (unsigned char b = mask[i]; b; b &= (unsigned char)(b - 1)) n++;
    }
    return n > 0 ? n : 1;
}

/* RAM in pages from sysinfo: bytes (times mem_unit) over the page size. */
static long ram_pages(int free_ram) {
    unsigned char info[128];
    long r = MSYS1(SYS_sysinfo, info);
    if (__moqi_is_error(r)) {
        errno = (int)-r;
        return -1;
    }
    unsigned long bytes;
    unsigned int unit;
    memcpy(&bytes, info + (free_ram ? 40 : 32), 8);
    memcpy(&unit, info + 104, 4);
    if (unit == 0) unit = 1;
    return (long)((bytes * unit) / 4096UL);
}

long sysconf(int name) {
    switch (name) {
    case _SC_ARG_MAX: return 2097152;
    case _SC_CHILD_MAX: return 63;
    case _SC_CLK_TCK: return 100;
    case _SC_NGROUPS_MAX: return 65536;
    case _SC_OPEN_MAX: return 64;
    case _SC_PAGESIZE: return 4096;
    case _SC_IOV_MAX: return 1024;
    case _SC_LOGIN_NAME_MAX: return 256;
    case _SC_LINE_MAX: return 2048;
    case _SC_HOST_NAME_MAX: return HOST_NAME_MAX;
    case _SC_NPROCESSORS_CONF:
    case _SC_NPROCESSORS_ONLN: return cpu_count();
    case _SC_PHYS_PAGES: return ram_pages(0);
    case _SC_AVPHYS_PAGES: return ram_pages(1);
    default:
        errno = EINVAL;
        return -1;
    }
}
