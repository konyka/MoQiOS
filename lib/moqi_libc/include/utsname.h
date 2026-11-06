/* utsname.h -- uname for moqi_libc. struct utsname is glibc's: six 65-byte NUL-padded fields (sysname 0, nodename 65, release 130,
 * version 195, machine 260, domainname 325), 390 bytes. uname returns 0, or -1 with errno (EFAULT). */
#ifndef MOQI_UTSNAME_H
#define MOQI_UTSNAME_H

struct utsname {
    char sysname[65];
    char nodename[65];
    char release[65];
    char version[65];
    char machine[65];
    char domainname[65];
};

int uname(struct utsname *buf);

#endif
