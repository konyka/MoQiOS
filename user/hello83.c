// hello83 - raw epoll_create1 flag boundary acceptance.
#include <stdint.h>
static inline int64_t s1(uint64_t n,uint64_t a){int64_t r;__asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a):"rcx","r11","memory");return r;}
static inline void p(const char*s){uint64_t n=0;while(s[n])n++;int64_t r;register uint64_t x __asm__("rdx")=n;__asm__ volatile("syscall":"=a"(r):"a"(1),"D"((uint64_t)1),"S"((uint64_t)s),"r"(x):"rcx","r11","memory");}
__attribute__((noreturn)) static void ex(int x){s1(2,(uint64_t)x);for(;;){}}
void _start(void){int f=0;p("hello83: start\n");int64_t good=s1(146,0);if(good<0)f=1;else s1(3,(uint64_t)good);int64_t bad=s1(146,0x80000);if(bad!=-22)f=1;if(!f)p("hello83: PASS\nhello83 done\n");else p("hello83: FAIL\nhello83 done\n");ex(f);}
