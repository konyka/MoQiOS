//! Pure errno rules for the namespace calls on a filesystem that has
//! directories, files and symlinks (ext2, tmpfs): what unlink, rmdir, mkdir
//! and open answer for an object that exists, or does not.

pub const Kind = enum { missing, file, directory, symlink };

const O_ACCMODE: u32 = 0x3;
const O_CREAT: u32 = 0x40;
const O_EXCL: u32 = 0x80;
const O_TRUNC: u32 = 0x200;
const O_DIRECTORY: u32 = 0x10000;
const O_NOFOLLOW: u32 = 0x20000;

pub fn unlink(k: Kind) i64 {
    return switch (k) {
        .missing => -2, // ENOENT
        .directory => -21, // EISDIR
        .file, .symlink => 0,
    };
}

pub fn rmdir(k: Kind, empty: bool) i64 {
    return switch (k) {
        .missing => -2,
        .file, .symlink => -20, // ENOTDIR
        .directory => if (empty) 0 else -39, // ENOTEMPTY
    };
}

pub fn mkdir(k: Kind) i64 {
    return if (k == .missing) 0 else -17; // EEXIST
}

/// open() of an object that exists. Order follows Linux: O_CREAT|O_EXCL first,
/// then O_NOFOLLOW on a symlink, then the directory rules.
pub fn openExisting(k: Kind, flags: u32) i64 {
    if ((flags & O_CREAT) != 0 and (flags & O_EXCL) != 0) return -17;
    if (k == .symlink and (flags & O_NOFOLLOW) != 0) {
        return if ((flags & O_DIRECTORY) != 0) -20 else -40; // ENOTDIR / ELOOP
    }
    switch (k) {
        .directory => {
            if ((flags & O_ACCMODE) != 0 or (flags & O_TRUNC) != 0) return -21; // EISDIR
            return 0;
        },
        .file => return if ((flags & O_DIRECTORY) != 0) -20 else 0,
        else => return 0,
    }
}

pub fn openMissing(flags: u32) i64 {
    return if ((flags & O_CREAT) != 0) 0 else -2;
}

/// read(2) on a descriptor: the errno the descriptor kind alone decides, or 0
/// when the read may proceed to the filesystem.
pub fn readGate(is_directory: bool) i64 {
    return if (is_directory) -21 else 0; // EISDIR
}

/// write(2)/pwrite(2): a descriptor not open for writing is EBADF (a
/// directory is never open for writing, so it is EBADF too on Linux when
/// opened read-only; opening one for writing already failed with EISDIR).
pub fn writeGate(writable: bool) i64 {
    return if (writable) 0 else -9; // EBADF
}

/// Classify the result of `copyPathFromUser(buf, ptr, max)`: it returns the
/// bytes copied including the NUL, `max` when no NUL appeared within `max`
/// bytes, and 0 when the string ran into unreadable memory. A full window with
/// no terminator means the path is longer than the kernel accepts (ENAMETOOLONG)
/// rather than something to truncate and act on.
pub fn pathCopyErrno(buf: []const u8, copied: usize, max: usize) i64 {
    if (copied == 0) return -14; // EFAULT
    if (copied < max) return 0;
    // copied == max: fits only if the last copied byte is the terminator
    return if (buf[copied - 1] == 0) 0 else -36;
}

pub const PathCopy = union(enum) { ok: []const u8, err: i64 };

/// The NUL-terminated name inside `buf` after a `copyPathFromUser(buf, ptr, max)`
/// that returned `copied`, or EFAULT / ENAMETOOLONG (see pathCopyErrno).
pub fn pathFromCopy(buf: []const u8, copied: usize, max: usize) PathCopy {
    const rc = pathCopyErrno(buf, copied, max);
    if (rc != 0) return .{ .err = rc };
    var n: usize = 0;
    while (n < copied and buf[n] != 0) : (n += 1) {}
    return .{ .ok = buf[0..n] };
}

/// pread/pwrite take a signed off_t; a negative value is EINVAL.
pub fn positionedOffsetErrno(offset: u64) i64 {
    return if ((offset >> 63) != 0) -22 else 0;
}

pub const TailZero = struct { block: u32, from: u32, len: u32 };

/// After a file is cut down to `new_size`, the last block it still owns keeps
/// the old bytes past the new end. They must be zeroed, or a later extension
/// (ftruncate up, or a write past the end that leaves a hole) shows data that
/// was supposed to be gone. Null when the size falls on a block boundary.
pub fn truncateTail(new_size: u32, block_size: u32) ?TailZero {
    if (new_size == 0 or block_size == 0 or new_size % block_size == 0) return null;
    const from = new_size % block_size;
    return .{ .block = new_size / block_size, .from = from, .len = block_size - from };
}

const FD_CLOEXEC: u32 = 1;

/// Descriptor flags of a duplicate: FD_CLOEXEC is a property of the descriptor,
/// not of the open file, so a copy gets exactly what the caller asked for and
/// never inherits the source's bit.
pub fn dupFdFlags(source_flags: u32, want_cloexec: bool) u32 {
    _ = source_flags;
    return if (want_cloexec) FD_CLOEXEC else 0;
}

/// F_GETFL access mode of a pipe end: O_RDONLY (0) for the read end, O_WRONLY (1) for the write end.
pub fn pipeStatusFlags(write_end: bool) u32 {
    return if (write_end) 1 else 0;
}

/// What a socket operation that cannot make progress right now should do.
pub const SockWait = enum { proceed, wait, eagain, eof };

/// MSG_DONTWAIT (0x40) on this call, or O_NONBLOCK (0x800) on the descriptor.
pub fn nonblockRequested(status_flags: u32, msg_flags: u32) bool {
    return (status_flags & 0x800) != 0 or (msg_flags & 0x40) != 0;
}

/// Receive with an empty queue. `peer_gone`: a stream whose peer is closed or
/// never connected can never get data, which is end-of-file and never a wait.
pub fn recvWait(nonblock: bool, queue_empty: bool, peer_gone: bool) SockWait {
    if (!queue_empty) return .proceed;
    if (peer_gone) return .eof;
    return if (nonblock) .eagain else .wait;
}

/// accept with an empty backlog.
pub fn acceptWait(nonblock: bool) SockWait {
    return if (nonblock) .eagain else .wait;
}

/// Send when the peer's buffer may be full.
/// What a stream write loop does after one attempt put `result` bytes (or a
/// negative errno) into the peer's ring, `done` bytes already sent of `total`.
/// Blocking writes keep going until everything is sent; a non-blocking write
/// reports what fitted (EAGAIN only when nothing did); an error after some
/// progress reports the progress.
pub const WriteStep = enum { done, again, wait, partial, fail };

pub fn writeProgress(total: usize, done: usize, result: i64, nonblock: bool) WriteStep {
    if (total == 0) return .done;
    if (result > 0) {
        const sent = done + @as(usize, @intCast(result));
        if (sent >= total) return .done;
        return if (nonblock) .partial else .again;
    }
    if (result == -11) {
        if (nonblock) return if (done > 0) .partial else .fail;
        return .wait;
    }
    return if (done > 0) .partial else .fail;
}

/// A socket send that failed with EPIPE also raises SIGPIPE at the caller,
/// unless the call passed MSG_NOSIGNAL (POSIX / Linux).
pub const MSG_NOSIGNAL: u32 = 0x4000;

pub fn raisesSigpipe(result: i64, msg_flags: u32) bool {
    return result == -32 and (msg_flags & MSG_NOSIGNAL) == 0;
}

/// Pass `result` through, raising SIGPIPE on the current task first when the
/// send policy asks for it.
pub fn sendResult(result: i64, msg_flags: u32) i64 {
    if (raisesSigpipe(result, msg_flags)) {
        const sig_mod = @import("../proc/signal.zig");
        sig_mod.raiseSelf(sig_mod.SIGPIPE);
    }
    return result;
}

/// Whether read() asks the descriptor for another chunk after a full one.
/// Regular files always have the next bytes; a pipe, socket or device may have
/// none yet, and a blocking read would then wait for data the caller never
/// needed to have (POSIX: a stream read returns what is available).
pub fn readContinues(regular_file: bool, ready: bool) bool {
    return regular_file or ready;
}

/// Result of a blocking write whose SO_SNDTIMEO ran out: what was already sent,
/// or EAGAIN when nothing was.
pub fn sendTimeoutResult(done: usize) i64 {
    return if (done > 0) @intCast(done) else -11;
}

/// A datagram is sent whole or not at all: it can never be larger than the ring
/// (the receiver could never hold it), and otherwise only waits for room.
pub const DGRAM_PREFIX: usize = 2;

pub fn dgramFits(len: usize, ring_size: usize) bool {
    return len + DGRAM_PREFIX <= ring_size;
}

pub fn sendWait(nonblock: bool, buffer_full: bool) SockWait {
    if (!buffer_full) return .proceed;
    return if (nonblock) .eagain else .wait;
}

pub const SocketArgs = struct { sock_type: u32, cloexec: bool, nonblock: bool };

const SOCK_NONBLOCK_FLAG: u32 = 0x800;
const SOCK_CLOEXEC_FLAG: u32 = 0x80000;

/// socket(domain, type, protocol): split the type from its SOCK_CLOEXEC /
/// SOCK_NONBLOCK flags and validate the combination as Linux does.
pub fn socketArgs(domain: u32, type_and_flags: u32, protocol: u32) union(enum) { ok: SocketArgs, err: i64 } {
    if (domain != 1 and domain != 2 and domain != 10) return .{ .err = -97 }; // EAFNOSUPPORT
    const flags = SOCK_NONBLOCK_FLAG | SOCK_CLOEXEC_FLAG;
    if ((type_and_flags & ~(flags | 0xf)) != 0) return .{ .err = -22 };
    const t = type_and_flags & 0xf;
    if (t < 1 or t > 3) return .{ .err = -22 }; // STREAM, DGRAM, RAW
    if (domain == 1) {
        if (t == 3) return .{ .err = -22 };
        if (protocol != 0) return .{ .err = -93 }; // EPROTONOSUPPORT
    } else if (t == 1) {
        if (protocol != 0 and protocol != 6) return .{ .err = -93 };
    } else if (t == 2) {
        if (protocol != 0 and protocol != 17) return .{ .err = -93 };
    }
    return .{ .ok = .{ .sock_type = t, .cloexec = (type_and_flags & SOCK_CLOEXEC_FLAG) != 0, .nonblock = (type_and_flags & SOCK_NONBLOCK_FLAG) != 0 } };
}

/// The errno for a descriptor argument of a socket call.
pub fn socketFdErrno(fd_open: bool, is_socket: bool) i64 {
    if (!fd_open) return -9; // EBADF
    return if (is_socket) 0 else -88; // ENOTSOCK
}

/// Half-close state of a stream socket pair (shutdown(2)). `shut_rd`/`shut_wr`
/// are this end's flags, `peer_*` the other end's.
pub const HalfClose = struct { shut_rd: bool = false, shut_wr: bool = false, peer_shut_rd: bool = false, peer_shut_wr: bool = false };

/// An empty receive ring reads EOF once this end shut its read side or the
/// peer shut its write side (the peer's earlier bytes are still delivered first).
pub fn halfCloseReadEof(h: HalfClose) bool {
    return h.shut_rd or h.peer_shut_wr;
}

/// A send fails with EPIPE once this end shut its write side or the peer shut
/// its read side.
pub fn halfCloseSendBroken(h: HalfClose) bool {
    return h.shut_wr or h.peer_shut_rd;
}

pub const StreamView = struct { connected: bool, queued: bool };
pub const StreamSend = enum { deliver, queue_pending, not_connected };

/// A stream client whose connect() succeeded but which the listener has not
/// accepted yet is `queued`: it may send (the bytes wait for accept) and its
/// reads must wait. Only a socket that is neither connected nor queued is
/// really unconnected (ENOTCONN on send, EOF on read).
pub fn streamSendState(v: StreamView) StreamSend {
    if (v.connected) return .deliver;
    return if (v.queued) .queue_pending else .not_connected;
}

pub fn streamRecvState(v: StreamView, nonblock: bool) SockWait {
    if (v.connected) return if (nonblock) .eagain else .wait;
    if (v.queued) return if (nonblock) .eagain else .wait;
    return .eof;
}

/// send() on a stream socket that is not delivering. A socket that was once
/// connected and whose peer has since closed is EPIPE; one that never was
/// connected is ENOTCONN.
pub fn streamSendErrno(was_connected: bool, peer_alive: bool) i64 {
    if (peer_alive) return 0;
    return if (was_connected) -32 else -107;
}
