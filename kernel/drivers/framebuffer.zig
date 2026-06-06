/// Framebuffer graphics driver.
///
/// Uses the Limine bootloader's linear framebuffer for graphical output.
/// Provides pixel-level drawing primitives: putPixel, fillRect, drawLine,
/// blit, clear. Optional double-buffering when memory is available.
const limine = @import("../limine.zig");
const main_mod = @import("../main.zig");
const serial = @import("../arch/x86_64/serial.zig");
const klog = @import("../klog.zig");
const pmm = @import("../mm/pmm.zig");
const hhdm = @import("../mm/hhdm.zig");
const paging = @import("../arch/x86_64/paging.zig");
const fmt = @import("../lib/fmt.zig");

var fb_addr: [*]u8 = undefined; // 帧缓冲线性地址
var fb_width: u32 = 0;
var fb_height: u32 = 0;
var fb_pitch: u32 = 0; // 每行字节数
var fb_bpp: u16 = 0; // 每像素位数 (通常 32)
var fb_size: u64 = 0;
var initialized: bool = false;

// 双缓冲
var back_buffer: ?[*]u8 = null; // 后缓冲（如果能分配）
var back_buffer_phys: u64 = 0;

pub fn init() void {
    serial.writeString("[framebuffer] Initializing...\n");

    const resp = main_mod.framebuffer_request.response orelse {
        serial.writeString("[framebuffer] No framebuffer response from Limine, skipping\n");
        return;
    };

    // 至少需要 1 个 framebuffer
    if (resp.framebuffer_count == 0) {
        serial.writeString("[framebuffer] No framebuffers available, skipping\n");
        return;
    }

    const fb = resp.framebuffers[0];

    fb_addr = fb.address;
    fb_width = @intCast(fb.width);
    fb_height = @intCast(fb.height);
    fb_pitch = @intCast(fb.pitch);
    fb_bpp = fb.bpp;
    fb_size = @as(u64, fb_pitch) * fb.height;

    // 尝试分配双缓冲
    initBackBuffer();

    initialized = true;

    serial.writeString("[framebuffer] ");
    fmt.writeDecimal(fb_width);
    serial.writeString("x");
    fmt.writeDecimal(fb_height);
    serial.writeString("x");
    fmt.writeDecimal(fb_bpp);
    serial.writeString(" pitch=");
    fmt.writeDecimal(fb_pitch);
    if (back_buffer != null) {
        serial.writeString(" double-buffered");
    }
    serial.writeString("\n");
}

fn initBackBuffer() void {
    // 计算需要的页数
    const pages_needed = (fb_size + paging.PAGE_SIZE - 1) / paging.PAGE_SIZE;
    if (pages_needed == 0 or pages_needed > 64) {
        // 过大或不合理，跳过双缓冲
        return;
    }

    // 分配连续物理页
    const phys = pmm.allocPage() orelse return;
    const virt = hhdm.physToVirt(phys);

    // 如果需要多页，逐页映射
    if (pages_needed > 1) {
        const pml4 = paging.getKernelPml4();
        const flags = paging.MapFlags{
            .writable = true,
            .user = false,
            .no_execute = true,
            .global = true,
        };
        var i: u64 = 1;
        while (i < pages_needed) : (i += 1) {
            const extra_phys = pmm.allocPage() orelse {
                // 分配失败，放弃双缓冲
                serial.writeString("[framebuffer] Back buffer allocation failed, single-buffered\n");
                return;
            };
            paging.mapPage(pml4, virt + i * paging.PAGE_SIZE, extra_phys, flags) catch {
                pmm.freePage(extra_phys);
                serial.writeString("[framebuffer] Back buffer map failed, single-buffered\n");
                return;
            };
        }
    }

    back_buffer_phys = phys;
    back_buffer = @ptrFromInt(virt);

    // 清零后缓冲
    var bb = back_buffer.?;
    @memset(bb[0..fb_size], 0);

    serial.writeString("[framebuffer] Back buffer allocated (");
    fmt.writeDecimal64(pages_needed);
    serial.writeString(" pages)\n");
}

pub fn putPixel(x: u32, y: u32, color: u32) void {
    if (!initialized) return;
    if (x >= fb_width or y >= fb_height) return;

    const bytes_per_pixel: u64 = fb_bpp / 8;
    const offset: u64 = @as(u64, y) * fb_pitch + @as(u64, x) * bytes_per_pixel;

    if (bytes_per_pixel == 4) {
        // 32-bit: 直接写入 u32
        const ptr: *u32 = @ptrCast(@alignCast(fb_addr + offset));
        ptr.* = color;
        // 同时写入后缓冲
        if (back_buffer) |bb| {
            const bptr: *u32 = @ptrCast(@alignCast(bb + offset));
            bptr.* = color;
        }
    } else if (bytes_per_pixel == 3) {
        // 24-bit: 写入低 3 字节
        fb_addr[offset] = @truncate(color);
        fb_addr[offset + 1] = @truncate(color >> 8);
        fb_addr[offset + 2] = @truncate(color >> 16);
    }
}

pub fn fillRect(x: u32, y: u32, w: u32, h: u32, color: u32) void {
    if (!initialized) return;

    const x_end = if (x + w > fb_width) fb_width else x + w;
    const y_end = if (y + h > fb_height) fb_height else y + h;

    // 优化: 32bpp 使用 memcpy 风格的逐行填充
    if (fb_bpp == 32) {
        const bytes_per_pixel: u64 = 4;
        var row: u32 = y;
        while (row < y_end) : (row += 1) {
            const row_offset: u64 = @as(u64, row) * fb_pitch + @as(u64, x) * bytes_per_pixel;
            const pixel_count = x_end - x;
            // 在帧缓冲上逐像素写入
            var col: u32 = 0;
            while (col < pixel_count) : (col += 1) {
                const ptr: *u32 = @ptrCast(@alignCast(fb_addr + row_offset + @as(u64, col) * 4));
                ptr.* = color;
            }
        }
        // 同步到后缓冲
        if (back_buffer) |bb| {
            row = y;
            while (row < y_end) : (row += 1) {
                const row_offset: u64 = @as(u64, row) * fb_pitch + @as(u64, x) * bytes_per_pixel;
                const pixel_count = x_end - x;
                var col: u32 = 0;
                while (col < pixel_count) : (col += 1) {
                    const ptr: *u32 = @ptrCast(@alignCast(bb + row_offset + @as(u64, col) * 4));
                    ptr.* = color;
                }
            }
        }
    } else {
        // 回退到逐像素
        var row: u32 = y;
        while (row < y_end) : (row += 1) {
            var col: u32 = x;
            while (col < x_end) : (col += 1) {
                putPixel(col, row, color);
            }
        }
    }
}

/// Bresenham 画线算法
pub fn drawLine(x0: u32, y0: u32, x1: u32, y1: u32, color: u32) void {
    if (!initialized) return;

    var dx: i64 = @as(i64, x1) - @as(i64, x0);
    var dy: i64 = @as(i64, y1) - @as(i64, y0);

    const sx: i64 = if (dx >= 0) 1 else -1;
    const sy: i64 = if (dy >= 0) 1 else -1;

    dx = if (dx >= 0) dx else -dx;
    dy = if (dy >= 0) dy else -dy;

    var err: i64 = dx - dy;
    var cx: i64 = x0;
    var cy: i64 = y0;

    while (true) {
        if (cx >= 0 and cy >= 0) {
            putPixel(@intCast(cx), @intCast(cy), color);
        }
        if (cx == x1 and cy == y1) break;

        const e2 = 2 * err;
        if (e2 > -dy) {
            err -= dy;
            cx += sx;
        }
        if (e2 < dx) {
            err += dx;
            cy += sy;
        }
    }
}

/// 将像素数据块拷贝到帧缓冲
pub fn blit(x: u32, y: u32, w: u32, h: u32, data: [*]const u32) void {
    if (!initialized) return;

    var row: u32 = 0;
    while (row < h and (y + row) < fb_height) : (row += 1) {
        var col: u32 = 0;
        while (col < w and (x + col) < fb_width) : (col += 1) {
            putPixel(x + col, y + row, data[row * w + col]);
        }
    }
}

pub fn clear(color: u32) void {
    fillRect(0, 0, fb_width, fb_height, color);
}

/// 双缓冲交换（如果有后缓冲）
pub fn swap() void {
    if (!initialized) return;
    if (back_buffer) |bb| {
        @memcpy(fb_addr[0..fb_size], bb[0..fb_size]);
    }
}

pub fn getInfo() struct { width: u32, height: u32, pitch: u32, bpp: u16 } {
    return .{ .width = fb_width, .height = fb_height, .pitch = fb_pitch, .bpp = fb_bpp };
}

pub fn getFramebufferAddr() ?[*]u8 {
    if (!initialized) return null;
    return fb_addr;
}

pub fn isInitialized() bool {
    return initialized;
}

pub fn getWidth() u32 {
    return fb_width;
}

pub fn getHeight() u32 {
    return fb_height;
}

pub fn getPitch() u32 {
    return fb_pitch;
}

pub fn getBpp() u16 {
    return fb_bpp;
}
