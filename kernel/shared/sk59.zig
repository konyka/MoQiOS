//! SK-59 — full TCP engine (`net/tcp.zig`) links on non-x86.
//!
//! After SK-54 (pure helpers) and SK-58 (rdtsc → arch.tsc facade), tcp.zig no
//! longer has a hard x86 dependency: its imports (nic/netif/eth/ipv4/arp/
//! socket_opt/tcp_util/IrqSpinlock) are all arch-clean, and socket_opt's
//! sched/task/copy_from_user imports are function-local + lazy (tcp only uses
//! the SocketOptions struct). This probe forces analysis of every public entry
//! point on riscv64/aarch64 (compiling the whole state machine, retransmit,
//! congestion control, SACK, options) and exercises a few safe read paths on an
//! uninitialised TCB table: no connection is active, so queries return the
//! closed/empty defaults without faulting.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const tcp = @import("../net/tcp.zig");

pub fn announce() void {
    if (comptime builtin.cpu.arch == .x86_64) {
        arch.serial.writeString("[SK-59] tcp engine links non-x86: OK\n");
        return;
    }

    // Force full analysis of the TCP engine on this arch.
    comptime {
        _ = &tcp.initTcbs;
        _ = &tcp.tcpRetain;
        _ = &tcp.tcpGetOptions;
        _ = &tcp.tcpSetOptions;
        _ = &tcp.tcpClearSoError;
        _ = &tcp.handlePacket;
        _ = &tcp.tcpConnect;
        _ = &tcp.tcpConnectSocket;
        _ = &tcp.tcpPoll;
        _ = &tcp.tcpSend;
        _ = &tcp.tcpRecv;
        _ = &tcp.tcpFlushCork;
        _ = &tcp.tcpFlushAck;
        _ = &tcp.tcpClose;
        _ = &tcp.tcpState;
        _ = &tcp.isEstablished;
        _ = &tcp.isClosed;
        _ = &tcp.timerTick;
        _ = &tcp.tcpSocket;
        _ = &tcp.tcpBind;
        _ = &tcp.tcpListen;
        _ = &tcp.tcpAccept;
        _ = &tcp.getTcbIdx;
        _ = &tcp.tcpRecvAvailable;
        _ = &tcp.tcpSendSpace;
        _ = &tcp.tcpIsClosing;
        _ = &tcp.tcpGetAddrInfo;
        _ = &tcp.tcpShutdown;
    }

    // Exercise safe read paths on a fresh (all-inactive) TCB table.
    tcp.initTcbs();

    // Out-of-range / inactive index queries return closed/empty defaults.
    if (tcp.getTcbIdx(9999) != null) {
        arch.serial.writeString("[SK-59] FAILED: bogus tcb active\n");
        return;
    }
    if (tcp.tcpRecvAvailable(0) != 0 or tcp.tcpSendSpace(0) != 0) {
        arch.serial.writeString("[SK-59] FAILED: fresh tcb has data\n");
        return;
    }
    if (!tcp.isClosed(0) or tcp.isEstablished(0)) {
        arch.serial.writeString("[SK-59] FAILED: fresh tcb not closed\n");
        return;
    }
    if (!tcp.tcpIsClosing(9999)) {
        arch.serial.writeString("[SK-59] FAILED: oob not treated closing\n");
        return;
    }
    if (tcp.tcpGetAddrInfo(0) != null) {
        arch.serial.writeString("[SK-59] FAILED: inactive addr info\n");
        return;
    }

    // A runt ICMP-sized buffer into the TCP handler must be ignored safely.
    var junk: [4]u8 = .{ 0, 0, 0, 0 };
    tcp.handlePacket(.{ 10, 0, 2, 2 }, .{ 10, 0, 2, 15 }, &junk, junk.len);

    // timerTick on an idle table must not fault.
    tcp.timerTick(10);

    arch.serial.writeString("[SK-59] tcp engine links non-x86: OK\n");
}
