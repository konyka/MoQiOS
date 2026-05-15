/// Page frame descriptor — per-page metadata for physical page tracking.
/// One PageFrame per 4KB physical page, stored in a contiguous array.

pub const PageFrame = packed struct {
    ref_count: u16 = 0,
    flags: packed struct {
        reserved: bool = false,
        kernel: bool = false,
        dma: bool = false,
        cow: bool = false,
        _pad: u4 = 0,
    } = .{},

    pub inline fn isUsed(self: PageFrame) bool {
        return self.ref_count > 0;
    }
};

/// Global page frame array — one PageFrame per 4KB physical page.
/// Initialized by PMM during init().
pub var frames: [*]PageFrame = undefined;
pub var frame_count: u64 = 0;

pub fn init(total_pages: u64, frames_ptr: [*]PageFrame) void {
    frame_count = total_pages;
    frames = frames_ptr;
    // Zero all frames
    const bytes: [*]u8 = @ptrCast(frames_ptr);
    @memset(bytes[0 .. total_pages * @sizeOf(PageFrame)], 0);
}
