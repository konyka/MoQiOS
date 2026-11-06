/* sysinfo.h -- host name, random bytes and system configuration for moqi_libc.
 *
 * gethostname copies the node name and a terminating NUL; when the buffer is shorter than name + 1 (including size 0) it fails with
 * ENAMETOOLONG and, for a non-empty buffer, fills it with the truncated name without a NUL (glibc does the same). getrandom is the
 * kernel call: it returns the number of bytes written, or -1 with errno (EINVAL for flags other than GRND_NONBLOCK, GRND_RANDOM,
 * GRND_INSECURE or for RANDOM together with INSECURE, EFAULT for a bad buffer). getentropy fills exactly `size` bytes (at most 256, EIO
 * beyond that) and returns 0, or -1 with errno. getpagesize is 4096.
 *
 * sysconf answers the names below with glibc's values on Linux x86-64; the numbers of the _SC_ names are glibc's. _SC_NPROCESSORS_ONLN and
 * _SC_NPROCESSORS_CONF count the bits of the affinity mask the kernel reports; _SC_PHYS_PAGES and _SC_AVPHYS_PAGES come from sysinfo
 * (total and free RAM in 4096-byte pages). A name that is not listed returns -1 with errno EINVAL, as glibc does for an unknown name; a
 * name that glibc knows but this library does not answer is also -1 with EINVAL (it is not reported as "unlimited").
 */
#ifndef MOQI_SYSINFO_H
#define MOQI_SYSINFO_H

#include <stddef.h>

#define GRND_NONBLOCK 0x1
#define GRND_RANDOM   0x2
#define GRND_INSECURE 0x4

#define HOST_NAME_MAX 64

#define _SC_ARG_MAX          0
#define _SC_CHILD_MAX        1
#define _SC_CLK_TCK          2
#define _SC_NGROUPS_MAX      3
#define _SC_OPEN_MAX         4
#define _SC_PAGESIZE         30
#define _SC_PAGE_SIZE        30
#define _SC_IOV_MAX          60
#define _SC_LOGIN_NAME_MAX   71
#define _SC_LINE_MAX         43
#define _SC_NPROCESSORS_CONF 83
#define _SC_NPROCESSORS_ONLN 84
#define _SC_PHYS_PAGES       85
#define _SC_AVPHYS_PAGES     86
#define _SC_HOST_NAME_MAX    180

int gethostname(char *name, size_t size);
long getrandom(void *buf, size_t size, unsigned int flags);
int getentropy(void *buf, size_t size);
int getpagesize(void);
long sysconf(int name);

#endif
