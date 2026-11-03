/* strfunc.c — the rest of string.h (see include/string.h). Straightforward byte-wise code; correctness over speed. */
#include "../include/stdlib.h"
#include "../include/string.h"

char *strncat(char *dst, const char *src, size_t n) {
    char *d = dst;
    while (*d) d++;
    size_t i = 0;
    while (i < n && src[i]) {
        d[i] = src[i];
        i++;
    }
    d[i] = '\0';
    return dst;
}

char *stpcpy(char *dst, const char *src) {
    while ((*dst = *src) != '\0') {
        dst++;
        src++;
    }
    return dst;
}

size_t strnlen(const char *s, size_t n) {
    size_t i = 0;
    while (i < n && s[i]) i++;
    return i;
}

char *strstr(const char *haystack, const char *needle) {
    if (*needle == '\0') return (char *)haystack;
    for (; *haystack; haystack++) {
        const char *h = haystack;
        const char *n = needle;
        while (*n && *h == *n) {
            h++;
            n++;
        }
        if (*n == '\0') return (char *)haystack;
    }
    return (char *)0;
}

void *memchr(const void *s, int c, size_t n) {
    const unsigned char *p = s;
    for (size_t i = 0; i < n; i++) {
        if (p[i] == (unsigned char)c) return (void *)(p + i);
    }
    return (void *)0;
}

void *memrchr(const void *s, int c, size_t n) {
    const unsigned char *p = s;
    for (size_t i = n; i > 0; i--) {
        if (p[i - 1] == (unsigned char)c) return (void *)(p + i - 1);
    }
    return (void *)0;
}

static int in_set(char c, const char *set) {
    for (; *set; set++) {
        if (*set == c) return 1;
    }
    return 0;
}

size_t strspn(const char *s, const char *accept) {
    size_t n = 0;
    while (s[n] && in_set(s[n], accept)) n++;
    return n;
}

size_t strcspn(const char *s, const char *reject) {
    size_t n = 0;
    while (s[n] && !in_set(s[n], reject)) n++;
    return n;
}

char *strpbrk(const char *s, const char *accept) {
    size_t n = strcspn(s, accept);
    return s[n] ? (char *)s + n : (char *)0;
}

static int lower(int c) { return (c >= 'A' && c <= 'Z') ? c + ('a' - 'A') : c; }

int strcasecmp(const char *a, const char *b) {
    while (*a && lower((unsigned char)*a) == lower((unsigned char)*b)) {
        a++;
        b++;
    }
    return lower((unsigned char)*a) - lower((unsigned char)*b);
}

int strncasecmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        int x = lower((unsigned char)a[i]);
        int y = lower((unsigned char)b[i]);
        if (x != y) return x - y;
        if (x == 0) return 0;
    }
    return 0;
}

char *strndup(const char *s, size_t n) {
    size_t len = strnlen(s, n);
    char *p = (char *)malloc(len + 1);
    if (!p) return (char *)0;
    memcpy(p, s, len);
    p[len] = '\0';
    return p;
}

char *strdup(const char *s) {
    size_t len = strlen(s);
    char *p = (char *)malloc(len + 1);
    if (!p) return (char *)0;
    memcpy(p, s, len + 1);
    return p;
}

char *strtok_r(char *s, const char *delim, char **save) {
    if (!s) s = *save;
    s += strspn(s, delim);
    if (*s == '\0') {
        *save = s;
        return (char *)0;
    }
    char *token = s;
    s += strcspn(s, delim);
    if (*s) {
        *s = '\0';
        s++;
    }
    *save = s;
    return token;
}

static char *strtok_state;

char *strtok(char *s, const char *delim) {
    return strtok_r(s, delim, &strtok_state);
}

/* glibc's message for each errno value 0..135 (NULL: "Unknown error N"). */
static const char *const error_text[136] = {
    "Success", "Operation not permitted", "No such file or directory", "No such process", "Interrupted system call",
    "Input/output error", "No such device or address", "Argument list too long", "Exec format error",
    "Bad file descriptor", "No child processes", "Resource temporarily unavailable", "Cannot allocate memory",
    "Permission denied", "Bad address", "Block device required", "Device or resource busy", "File exists",
    "Invalid cross-device link", "No such device", "Not a directory", "Is a directory", "Invalid argument",
    "Too many open files in system", "Too many open files", "Inappropriate ioctl for device", "Text file busy",
    "File too large", "No space left on device", "Illegal seek", "Read-only file system", "Too many links",
    "Broken pipe", "Numerical argument out of domain", "Numerical result out of range", "Resource deadlock avoided",
    "File name too long", "No locks available", "Function not implemented", "Directory not empty",
    "Too many levels of symbolic links", NULL, "No message of desired type", "Identifier removed",
    "Channel number out of range", "Level 2 not synchronized", "Level 3 halted", "Level 3 reset",
    "Link number out of range", "Protocol driver not attached", "No CSI structure available", "Level 2 halted",
    "Invalid exchange", "Invalid request descriptor", "Exchange full", "No anode", "Invalid request code",
    "Invalid slot", NULL, "Bad font file format", "Device not a stream", "No data available", "Timer expired",
    "Out of streams resources", "Machine is not on the network", "Package not installed", "Object is remote",
    "Link has been severed", "Advertise error", "Srmount error", "Communication error on send", "Protocol error",
    "Multihop attempted", "RFS specific error", "Bad message", "Value too large for defined data type",
    "Name not unique on network", "File descriptor in bad state", "Remote address changed",
    "Can not access a needed shared library", "Accessing a corrupted shared library",
    ".lib section in a.out corrupted", "Attempting to link in too many shared libraries",
    "Cannot exec a shared library directly", "Invalid or incomplete multibyte or wide character",
    "Interrupted system call should be restarted", "Streams pipe error", "Too many users",
    "Socket operation on non-socket", "Destination address required", "Message too long",
    "Protocol wrong type for socket", "Protocol not available", "Protocol not supported", "Socket type not supported",
    "Operation not supported", "Protocol family not supported", "Address family not supported by protocol",
    "Address already in use", "Cannot assign requested address", "Network is down", "Network is unreachable",
    "Network dropped connection on reset", "Software caused connection abort", "Connection reset by peer",
    "No buffer space available", "Transport endpoint is already connected", "Transport endpoint is not connected",
    "Cannot send after transport endpoint shutdown", "Too many references: cannot splice", "Connection timed out",
    "Connection refused", "Host is down", "No route to host", "Operation already in progress",
    "Operation now in progress", "Stale file handle", "Structure needs cleaning", "Not a XENIX named type file",
    "No XENIX semaphores available", "Is a named type file", "Remote I/O error", "Disk quota exceeded",
    "No medium found", "Wrong medium type", "Operation canceled", "Required key not available", "Key has expired",
    "Key has been revoked", "Key was rejected by service", "Owner died", "State not recoverable",
    "Operation not possible due to RF-kill", "Memory page has hardware error", "Inappropriate file type or format",
    NULL,
};

char *strerror(int errnum) {
    if (errnum >= 0 && errnum < 136 && error_text[errnum]) return (char *)error_text[errnum];
    static char unknown[32];
    const char *prefix = "Unknown error ";
    size_t n = 0;
    while (prefix[n]) {
        unknown[n] = prefix[n];
        n++;
    }
    unsigned v = errnum < 0 ? 0u - (unsigned)errnum : (unsigned)errnum;
    char digits[12];
    size_t d = 0;
    do {
        digits[d++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    if (errnum < 0) unknown[n++] = '-';
    while (d) unknown[n++] = digits[--d];
    unknown[n] = '\0';
    return unknown;
}
