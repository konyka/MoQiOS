/// Higher Half Direct Map — Limine maps all physical RAM at a fixed virtual offset.

var hhdm_offset: u64 = 0;

pub fn init(offset: u64) void {
    hhdm_offset = offset;
}

pub fn physToVirt(phys: u64) u64 {
    return phys +% hhdm_offset;
}

pub fn virtToPhys(virt: u64) u64 {
    return virt -% hhdm_offset;
}

pub fn physToPtr(comptime T: type, phys: u64) *T {
    return @ptrFromInt(physToVirt(phys));
}

pub fn get() u64 {
    return hhdm_offset;
}
