// hello88 - bounded copy_file_range offsets, errors, and rollback acceptance.
#include <stdint.h>

static inline int64_t syscall1(uint64_t n,uint64_t a){int64_t r;__asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a):"rcx","r11","memory");return r;}
static inline int64_t syscall3(uint64_t n,uint64_t a,uint64_t b,uint64_t c){int64_t r;register uint64_t x __asm__("rdx")=c;__asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x):"rcx","r11","memory");return r;}
static inline int64_t syscall6(uint64_t n,uint64_t a,uint64_t b,uint64_t c,uint64_t d,uint64_t e,uint64_t f){int64_t r;register uint64_t x __asm__("rdx")=c;register uint64_t y __asm__("r10")=d;register uint64_t z __asm__("r8")=e;register uint64_t w __asm__("r9")=f;__asm__ volatile("syscall":"=a"(r):"a"(n),"D"(a),"S"(b),"r"(x),"r"(y),"r"(z),"r"(w):"rcx","r11","memory");return r;}

#define SYS_WRITE 1
#define SYS_EXIT 2
#define SYS_OPEN 9
#define SYS_READ 10
#define SYS_CLOSE 11
#define SYS_LSEEK 197
#define SYS_COPY_FILE_RANGE 184
#define O_RDWR_CREAT_TRUNC 0x242
#define O_RDONLY 0
#define EBADF 9
#define EFAULT 14
#define EINVAL 22

static int failures;
static void print(const char *s){uint64_t n=0;while(s[n])n++;syscall3(SYS_WRITE,1,(uint64_t)s,n);}
static int check(int ok,const char *s){if(!ok){print("hello88: FAIL ");print(s);print("\n");return 1;}return 0;}
__attribute__((noreturn)) static void exit_raw(int x){syscall1(SYS_EXIT,(uint64_t)x);for(;;){}}

void _start(void){
    print("hello88: start\n");
    int64_t src=syscall3(SYS_OPEN,(uint64_t)"/tmp/hello88-src",O_RDWR_CREAT_TRUNC,0666);
    int64_t dst=syscall3(SYS_OPEN,(uint64_t)"/tmp/hello88-dst",O_RDWR_CREAT_TRUNC,0666);
    failures+=check(src>=0&&dst>=0,"open regular source and destination");
    if(src>=0&&dst>=0){
        failures+=check(syscall3(SYS_WRITE,(uint64_t)src,(uint64_t)"abcdef",6)==6,"write source content");
        uint64_t in_off=1,out_off=2;
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,(uint64_t)src,(uint64_t)&in_off,(uint64_t)dst,(uint64_t)&out_off,3,0)==3,"explicit offset copy");
        failures+=check(in_off==4&&out_off==5,"explicit offsets write back");
        char source[3]={0,0,0};
        failures+=check(syscall3(SYS_LSEEK,(uint64_t)src,0,0)==0&&syscall3(SYS_READ,(uint64_t)src,(uint64_t)source,2)==2&&source[0]=='a'&&source[1]=='b',"explicit offsets restore descriptors");

        failures+=check(syscall3(SYS_LSEEK,(uint64_t)src,0,0)==0&&syscall3(SYS_LSEEK,(uint64_t)dst,0,0)==0,"reset implicit offsets");
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,(uint64_t)src,0,(uint64_t)dst,0,2,0)==2,"implicit offset copy");
        failures+=check(syscall3(SYS_LSEEK,(uint64_t)dst,0,0)==0,"rewind destination for validation");
        char copied[5]={0,0,0,0,0};
        failures+=check(syscall3(SYS_READ,(uint64_t)dst,(uint64_t)copied,5)==5&&copied[0]=='a'&&copied[1]=='b'&&copied[2]=='b'&&copied[3]=='c'&&copied[4]=='d',"copied content and size");

        uint64_t unchanged=0;
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,(uint64_t)src,1,(uint64_t)dst,1,1,0)==-EFAULT,"invalid offset pointer EFAULT");
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,(uint64_t)src,0,(uint64_t)dst,0,0,0)==-EINVAL,"zero length EINVAL");
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,(uint64_t)src,0,(uint64_t)dst,0,0x80000000ULL,0)==-EINVAL,"oversized length EINVAL");
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,64,0,(uint64_t)dst,0,1,0)==-EBADF,"invalid fd EBADF");
        failures+=check(syscall6(SYS_COPY_FILE_RANGE,1,0,(uint64_t)dst,0,1,0)==-EINVAL,"nonregular fd EINVAL");
        (void)unchanged;
        syscall1(SYS_CLOSE,(uint64_t)src); syscall1(SYS_CLOSE,(uint64_t)dst);
    }
    if(!failures)print("hello88: PASS\nhello88 done\n");else print("hello88: FAIL\nhello88 done\n");
    exit_raw(failures!=0);
}
