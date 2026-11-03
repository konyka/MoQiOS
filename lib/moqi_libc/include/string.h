/* string.h — freestanding string/memory routines for MoQiOS user programs. */
#ifndef MOQI_STRING_H
#define MOQI_STRING_H

#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n);
void *memmove(void *dst, const void *src, size_t n);
void *memset(void *dst, int c, size_t n);
int   memcmp(const void *a, const void *b, size_t n);

size_t strlen(const char *s);
int    strcmp(const char *a, const char *b);
int    strncmp(const char *a, const char *b, size_t n);
char  *strcpy(char *dst, const char *src);
char  *strncpy(char *dst, const char *src, size_t n);
char  *strcat(char *dst, const char *src);
char  *strchr(const char *s, int c);
char  *strrchr(const char *s, int c);

/* The rest of the C library's string interface, with glibc's behavior (compared against it over exhaustive small
 * inputs in host_tests/test_strfunc_abi.c). strdup/strndup allocate with malloc; the caller frees. strtok keeps its
 * position in static storage (not thread-safe); strtok_r keeps it in *save. strerror gives glibc's text for 0..133 and
 * "Unknown error N" otherwise, in a static buffer for the unknown case. */
char  *strncat(char *dst, const char *src, size_t n);
char  *stpcpy(char *dst, const char *src);
size_t strnlen(const char *s, size_t n);
char  *strstr(const char *haystack, const char *needle);
void  *memchr(const void *s, int c, size_t n);
void  *memrchr(const void *s, int c, size_t n);
size_t strspn(const char *s, const char *accept);
size_t strcspn(const char *s, const char *reject);
char  *strpbrk(const char *s, const char *accept);
int    strcasecmp(const char *a, const char *b);
int    strncasecmp(const char *a, const char *b, size_t n);
char  *strdup(const char *s);
char  *strndup(const char *s, size_t n);
char  *strtok(char *s, const char *delim);
char  *strtok_r(char *s, const char *delim, char **save);
char  *strerror(int errnum);
char  *strsignal(int sig);
void  *memmem(const void *haystack, size_t haystack_len, const void *needle, size_t needle_len);
char  *strcasestr(const char *haystack, const char *needle);

#endif /* MOQI_STRING_H */
