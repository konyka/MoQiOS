// hello85 - accept4 strict flags and pending-backlog preservation acceptance.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n, uint64_t a) { int64_t r; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a):"rcx","r11","memory"); return r; }
static inline int64_t syscall2(uint64_t n, uint64_t a, uint64_t b) { int64_t r; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b):"rcx","r11","memory"); return r; }
static inline int64_t syscall3(uint64_t n, uint64_t a, uint64_t b, uint64_t c) { int64_t r; register uint64_t x __asm__("rdx")=c; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x):"rcx","r11","memory"); return r; }
static inline int64_t syscall4(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d) { int64_t r; register uint64_t x __asm__("rdx")=c; register uint64_t y __asm__("r10")=d; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x),"r"(y):"rcx","r11","memory"); return r; }
static inline int64_t syscall6(uint64_t n, uint64_t a, uint64_t b, uint64_t c, uint64_t d, uint64_t e, uint64_t f) { int64_t r; register uint64_t x __asm__("rdx")=c; register uint64_t y __asm__("r10")=d; register uint64_t z __asm__("r8")=e; register uint64_t w __asm__("r9")=f; __asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x),"r"(y),"r"(z),"r"(w):"rcx","r11","memory"); return r; }

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_CLOSE 11
#define SYS_NETPOLL 104
#define SYS_SOCKET 117
#define SYS_BIND 118
#define SYS_LISTEN 119
#define SYS_ACCEPT4 131
#define SYS_CONNECT 124
#define AF_INET 2
#define SOCK_STREAM 1
#define ACCEPT4_CLOEXEC 0x80000
#define ACCEPT4_NONBLOCK 0x800
#define EINVAL 22
#define EAGAIN 11
#define TCP_PORT 18085

static void print(const char *s) { uint64_t n=0; while(s[n]) n++; syscall3(SYS_WRITE,1,(uint64_t)s,n); }
static int check(int ok,const char *s){if(!ok){print("hello85: FAIL ");print(s);print("\n");return 1;}return 0;}
static void addr(uint8_t *a){for(int i=0;i<16;i++)a[i]=0;a[0]=0; a[1]=2; a[2]=(uint8_t)(TCP_PORT>>8); a[3]=(uint8_t)TCP_PORT; a[4]=127;a[7]=1;}
__attribute__((noreturn)) static void exit_raw(int x){syscall1(SYS_EXIT,(uint64_t)x);for(;;){}}

void _start(void){
    int f=0; uint8_t sa[16]; addr(sa); print("hello85: start\n");
    int64_t listener=syscall3(SYS_SOCKET,AF_INET,SOCK_STREAM,0);
    f+=check(listener>=0,"create TCP listener");
    if(listener>=0){
        f+=check(syscall3(SYS_BIND,(uint64_t)listener,(uint64_t)sa,16)==0,"bind loopback listener");
        f+=check(syscall2(SYS_LISTEN,(uint64_t)listener,1)==0,"listen with pending backlog");
        int64_t client=syscall3(SYS_SOCKET,AF_INET,SOCK_STREAM,0);
        f+=check(client>=0,"create TCP client");
        if(client>=0){
            int64_t cr=syscall3(SYS_CONNECT,(uint64_t)client,(uint64_t)sa,16);
            if(cr<0) syscall1(SYS_NETPOLL,0);
            for(int i=0;i<20 && cr<0;i++){cr=syscall3(SYS_CONNECT,(uint64_t)client,(uint64_t)sa,16);if(cr<0)syscall1(SYS_NETPOLL,0);}
            f+=check(cr==0,"connect loopback client");
            syscall1(SYS_NETPOLL,0);
            int64_t bad=syscall4(SYS_ACCEPT4,(uint64_t)listener,0,0,0x40000000);
            f+=check(bad==-EINVAL,"unknown accept4 flag returns EINVAL");
            int64_t accepted=-1;
            for(int i=0;i<20 && accepted<0;i++){syscall1(SYS_NETPOLL,0);accepted=syscall4(SYS_ACCEPT4,(uint64_t)listener,0,0,ACCEPT4_CLOEXEC|ACCEPT4_NONBLOCK);}
            f+=check(accepted>=0,"valid accept4 consumes pending connection");
            if(accepted>=0)syscall1(SYS_CLOSE,(uint64_t)accepted);
            syscall1(SYS_CLOSE,(uint64_t)client);
        }
        syscall1(SYS_CLOSE,(uint64_t)listener);
    }
    if(!f)print("hello85: PASS\nhello85 done\n");else print("hello85: FAIL\nhello85 done\n");
    exit_raw(f!=0);
}
