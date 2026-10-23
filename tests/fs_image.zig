//! Test helper: a fs_reader.Reader over a filesystem image file.
const std = @import("std");
const fr = @import("kernel_shared").fs_reader;

pub const Image = struct {
    file: std.Io.File,
    io: std.Io,
    size: u64,
    reads: u64 = 0,

    pub fn open(path: []const u8) !Image {
        const io = std.testing.io;
        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        const st = try f.stat(io);
        return .{ .file = f, .io = io, .size = st.size };
    }

    pub fn close(self: *Image) void {
        self.file.close(self.io);
    }

    fn readFn(ctx: *anyopaque, offset: u64, buf: []u8) bool {
        const self: *Image = @ptrCast(@alignCast(ctx));
        if (offset > self.size or buf.len > self.size - offset) return false;
        var done: usize = 0;
        while (done < buf.len) {
            const n = self.file.readPositional(self.io, &.{buf[done..]}, offset + done) catch return false;
            if (n == 0) return false;
            done += n;
        }
        self.reads += 1;
        return true;
    }

    pub fn reader(self: *Image) fr.Reader {
        return .{ .ctx = self, .read_fn = readFn };
    }
};
