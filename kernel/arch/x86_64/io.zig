/// x86_64 I/O port operations

pub fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [port] "{dx}" (port),
          [val] "{al}" (val),
    );
}

pub fn outw(port: u16, val: u16) void {
    asm volatile ("outw %[val], %[port]"
        :
        : [port] "{dx}" (port),
          [val] "{ax}" (val),
    );
}

pub fn outl(port: u16, val: u32) void {
    asm volatile ("outl %[val], %[port]"
        :
        : [port] "{dx}" (port),
          [val] "{eax}" (val),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
    );
}

pub fn inw(port: u16) u16 {
    return asm volatile ("inw %[port], %[result]"
        : [result] "={ax}" (-> u16),
        : [port] "{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[port], %[result]"
        : [result] "={eax}" (-> u32),
        : [port] "{dx}" (port),
    );
}

pub fn ioWait() void {
    outb(0x80, 0);
}
