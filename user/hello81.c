// hello81 - bounded TCP sendmmsg/recvmmsg validation acceptance.
#include <stdint.h>
static inline int64_t syscall1(uint64_t n,uint64_t a){int64_t r;__asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a):"rcx","r11","memory");return r;}
static inline int64_t syscall4(uint64_t n,uint64_t a,uint64_t b,uint64_t c,uint64_t d){int64_t r;register uint64_t x __asm__("rdx")=c;register uint64_t y __asm__("r10")=d;__asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x),"r"(y):"rcx","r11","memory");return r;}
#define EINVAL 22
static void p(const char*s){uint64_t n=0;while(s[n])n++;syscall4(1,1,(uint64_t)s,n,0);}
static int c(int ok,const char*s){if(!ok){p("hello81: FAIL ");p(s);p("\n");return 1;}return 0;}
__attribute__((noreturn)) static void ex(int s){syscall1(2,(uint64_t)s);for(;;){}}
void _start(void){int f=0;p("hello81: start\n");f+=c(syscall4(135,3,0,0,0)==0,"sendmmsg vlen zero");f+=c(syscall4(134,3,0,0,0)==0,"recvmmsg vlen zero");f+=c(syscall4(135,3,0,17,0)==-EINVAL,"sendmmsg cap");f+=c(syscall4(134,3,0,17,0)==-EINVAL,"recvmmsg cap");f+=c(syscall4(135,0x7fffffff,1,1,0)<0,"sendmmsg first failure");f+=c(syscall4(134,0x7fffffff,1,1,0)<0,"recvmmsg first failure");if(!f)p("hello81: PASS (bounded TCP message batching)\nhello81 done\n");else p("hello81: FAIL\nhello81 done\n");ex(f!=0);}
