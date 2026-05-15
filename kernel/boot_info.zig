/// Boot information parsed from Limine responses.

const limine = @import("limine.zig");

pub const BootInfo = struct {
    hhdm_offset: u64,
    rsdp_address: u64,
    memmap_entries: u64,
    framebuffer_addr: u64,
    framebuffer_width: u64,
    framebuffer_height: u64,
    framebuffer_pitch: u64,
    framebuffer_bpp: u16,
};

pub fn parse() BootInfo {
    var info = BootInfo{
        .hhdm_offset = 0,
        .rsdp_address = 0,
        .memmap_entries = 0,
        .framebuffer_addr = 0,
        .framebuffer_width = 0,
        .framebuffer_height = 0,
        .framebuffer_pitch = 0,
        .framebuffer_bpp = 0,
    };

    if (@import("root").hhdm_request.response) |hhdm| {
        info.hhdm_offset = hhdm.offset;
    }

    if (@import("root").memmap_request.response) |memmap| {
        info.memmap_entries = memmap.entry_count;
    }

    return info;
}
