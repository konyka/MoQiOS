/// TCP protocol implementation for MoQiOS.
///
/// Supports: three-way handshake, data transfer with sequence numbers,
/// four-way close, retransmission, and sliding window.
///
/// Design constraints:
/// - No heap allocation — all state in static arrays (BSS)
/// - Single-core, no lock needed for TCB table
/// - Max 8 simultaneous connections
/// - Window size: 4096 bytes
/// - Retransmission: simple timeout-based (no SACK, no fast retransmit yet)

const e1000 = @import("../drivers/e1000.zig");
const netif = @import("netif.zig");
const eth = @import("eth.zig");
const ipv4 = @import("ipv4.zig");
const arp = @import("arp.zig");
const serial = @import("../arch/x86_64/serial.zig");

// ─── Constants ────────────────────────────────────────────────────────────

const MAX_CONNECTIONS: u32 = 8;
const TCP_WINDOW: u32 = 4096;
const TCP_MSS: u16 = 1460;
const SEND_BUF_SIZE: u32 = 8192;
const RECV_BUF_SIZE: u32 = 8192;
const RETRANSMIT_MS: u32 = 2000; // 2 second retransmit timeout

// TCP header flags
const FIN: u8 = 0x01;
const SYN: u8 = 0x02;
const RST: u8 = 0x04;
const PSH: u8 = 0x08;
const ACK: u8 = 0x10;

// TCP states (RFC 793)
const TcpState = enum(u8) {
    closed,
    syn_sent,
    syn_received,
    established,
    fin_wait_1,
    fin_wait_2,
    closing,
    time_wait,
    close_wait,
    last_ack,
    listen,
};

// ─── TCP Control Block (TCB) ──────────────────────────────────────────────

const TcpTcb = struct {
    local_port: u16,
    remote_port: u16,
    remote_ip: [4]u8,
    state: TcpState,

    // Sequence numbers
    snd_una: u32, // oldest unacknowledged
    snd_nxt: u32, // next to send
    snd_wnd: u32, // send window
    iss: u32, // initial send sequence

    rcv_nxt: u32, // next expected
    rcv_wnd: u32, // receive window
    irs: u32, // initial receive sequence

    // Send buffer (ring buffer)
    send_buf: [SEND_BUF_SIZE]u8,
    send_head: u32,
    send_tail: u32,
    send_unacked: u32, // offset into ring of first unacked byte

    // Receive buffer (ring buffer)
    recv_buf: [RECV_BUF_SIZE]u8,
    recv_head: u32,
    recv_tail: u32,

    // Retransmission
    retransmit_timer: u32, // ms since last ack
    retransmit_count: u8,

    // Connection metadata
    active: bool, // slot in use
    owner_task: u32, // task index that owns this connection
};

var tcbs: [MAX_CONNECTIONS]TcpTcb = undefined;

pub fn initTcbs() void {
    for (0..MAX_CONNECTIONS) |i| {
        tcbs[i] = .{
            .local_port = 0,
            .remote_port = 0,
            .remote_ip = .{0} ** 4,
            .state = .closed,
            .snd_una = 0,
            .snd_nxt = 0,
            .snd_wnd = TCP_WINDOW,
            .iss = 0,
            .rcv_nxt = 0,
            .rcv_wnd = TCP_WINDOW,
            .irs = 0,
            .send_buf = .{0} ** SEND_BUF_SIZE,
            .send_head = 0,
            .send_tail = 0,
            .send_unacked = 0,
            .recv_buf = .{0} ** RECV_BUF_SIZE,
            .recv_head = 0,
            .recv_tail = 0,
            .retransmit_timer = 0,
            .retransmit_count = 0,
            .active = false,
            .owner_task = 0,
        };
    }
}

var next_ephemeral_port: u16 = 49152;

// ─── Utilities ────────────────────────────────────────────────────────────

fn allocTcb() ?*TcpTcb {
    for (0..MAX_CONNECTIONS) |i| {
        if (!tcbs[i].active) {
            tcbs[i].active = true;
            tcbs[i].state = .closed;
            tcbs[i].send_head = 0;
            tcbs[i].send_tail = 0;
            tcbs[i].send_unacked = 0;
            tcbs[i].recv_head = 0;
            tcbs[i].recv_tail = 0;
            tcbs[i].retransmit_timer = 0;
            tcbs[i].retransmit_count = 0;
            return &tcbs[i];
        }
    }
    return null;
}

fn findTcbByTuple(local_port: u16, remote_port: u16, remote_ip: [4]u8) ?*TcpTcb {
    for (0..MAX_CONNECTIONS) |i| {
        if (tcbs[i].active and
            tcbs[i].local_port == local_port and
            tcbs[i].remote_port == remote_port and
            tcbs[i].remote_ip[0] == remote_ip[0] and
            tcbs[i].remote_ip[1] == remote_ip[1] and
            tcbs[i].remote_ip[2] == remote_ip[2] and
            tcbs[i].remote_ip[3] == remote_ip[3])
        {
            return &tcbs[i];
        }
    }
    return null;
}

fn findTcbByLocalPort(local_port: u16) ?*TcpTcb {
    for (0..MAX_CONNECTIONS) |i| {
        if (tcbs[i].active and tcbs[i].local_port == local_port) {
            return &tcbs[i];
        }
    }
    return null;
}

fn allocEphemeralPort() u16 {
    const port = next_ephemeral_port;
    next_ephemeral_port +|= 1;
    if (next_ephemeral_port < 49152) next_ephemeral_port = 49152;
    return port;
}

fn generateIss() u32 {
    // Simple ISS: combine TSC low bits with port numbers
    var tsc: u64 = 0;
    asm volatile ("rdtsc"
        : [result] "={rax}" (tsc),
    );
    return @truncate(tsc ^ (tsc >> 32));
}

// Ring buffer helpers
fn ringUsed(head: u32, tail: u32, size: u32) u32 {
    return (tail +% head) % size; // wrong — we need (tail - head) mod size
}

fn ringAvailable(head: u32, tail: u32, size: u32) u32 {
    if (tail >= head) return size - (tail - head) - 1;
    return head - tail - 1;
}

fn ringDataLen(head: u32, tail: u32, comptime size: u32) u32 {
    return (tail -% head) % size;
}

// ─── TCP Header Construction ──────────────────────────────────────────────

var send_pkt: [1518]u8 = @splat(0);

/// Build and send a TCP segment.
fn sendSegment(tcb: *TcpTcb, flags: u8, data: [*]const u8, data_len: u16) bool {
    const dst_mac = arp.resolve(tcb.remote_ip) orelse {
        serial.writeString("[tcp] ARP resolution failed\n");
        return false;
    };

    const our_mac = netif.getMac();
    const our_ip = netif.getOurIp();

    // TCP header at offset 34 (14 eth + 20 ipv4)
    const tcp_off = 34;
    const seq = tcb.snd_nxt;
    const ack = if (flags & ACK != 0) tcb.rcv_nxt else 0;
    const data_offset_val: u8 = 5; // 20 bytes, no options
    const window: u16 = @truncate(tcb.rcv_wnd);

    // Source port
    send_pkt[tcp_off + 0] = @intCast((tcb.local_port >> 8) & 0xFF);
    send_pkt[tcp_off + 1] = @intCast(tcb.local_port & 0xFF);
    // Destination port
    send_pkt[tcp_off + 2] = @intCast((tcb.remote_port >> 8) & 0xFF);
    send_pkt[tcp_off + 3] = @intCast(tcb.remote_port & 0xFF);
    // Sequence number
    send_pkt[tcp_off + 4] = @intCast((seq >> 24) & 0xFF);
    send_pkt[tcp_off + 5] = @intCast((seq >> 16) & 0xFF);
    send_pkt[tcp_off + 6] = @intCast((seq >> 8) & 0xFF);
    send_pkt[tcp_off + 7] = @intCast(seq & 0xFF);
    // Acknowledgment number
    send_pkt[tcp_off + 8] = @intCast((ack >> 24) & 0xFF);
    send_pkt[tcp_off + 9] = @intCast((ack >> 16) & 0xFF);
    send_pkt[tcp_off + 10] = @intCast((ack >> 8) & 0xFF);
    send_pkt[tcp_off + 11] = @intCast(ack & 0xFF);
    // Data offset (4 bits) + reserved (4 bits)
    send_pkt[tcp_off + 12] = data_offset_val << 4;
    // Flags
    send_pkt[tcp_off + 13] = flags;
    // Window
    send_pkt[tcp_off + 14] = @intCast((window >> 8) & 0xFF);
    send_pkt[tcp_off + 15] = @intCast(window & 0xFF);
    // Checksum placeholder
    send_pkt[tcp_off + 16] = 0;
    send_pkt[tcp_off + 17] = 0;
    // Urgent pointer
    send_pkt[tcp_off + 18] = 0;
    send_pkt[tcp_off + 19] = 0;

    // Copy data after TCP header
    if (data_len > 0) {
        @memcpy(send_pkt[tcp_off + 20 .. tcp_off + 20 + data_len], data[0..data_len]);
    }

    // Calculate TCP checksum (with pseudo-header)
    const tcp_total: u16 = 20 + data_len;
    const csum = tcpChecksum(our_ip, tcb.remote_ip, send_pkt[tcp_off ..].ptr, tcp_total);
    send_pkt[tcp_off + 16] = @intCast((csum >> 8) & 0xFF);
    send_pkt[tcp_off + 17] = @intCast(csum & 0xFF);

    // Build IPv4 header
    ipv4.buildHeader(send_pkt[14..].ptr, our_ip, tcb.remote_ip, ipv4.PROTO_TCP, tcp_total);

    // Build ethernet frame
    const frame_len = eth.buildFrame(&send_pkt, dst_mac, our_mac, eth.ETHERTYPE_IPV4, 20 + tcp_total);

    _ = e1000.sendPacket(&send_pkt, frame_len);

    // Advance snd_nxt for data payload
    if (data_len > 0) {
        tcb.snd_nxt +%= data_len;
    }
    // SYN and FIN consume one sequence number each
    if (flags & SYN != 0) {
        tcb.snd_nxt +%= 1;
    }
    if (flags & FIN != 0) {
        tcb.snd_nxt +%= 1;
    }

    return true;
}

/// TCP checksum with IPv4 pseudo-header.
fn tcpChecksum(src_ip: [4]u8, dst_ip: [4]u8, tcp_hdr: [*]const u8, tcp_len: u16) u16 {
    var sum: u32 = 0;

    // Pseudo-header
    sum +%= (@as(u32, src_ip[0]) << 8) | @as(u32, src_ip[1]);
    sum +%= (@as(u32, src_ip[2]) << 8) | @as(u32, src_ip[3]);
    sum +%= (@as(u32, dst_ip[0]) << 8) | @as(u32, dst_ip[1]);
    sum +%= (@as(u32, dst_ip[2]) << 8) | @as(u32, dst_ip[3]);
    sum +%= @as(u32, 6); // protocol
    sum +%= @as(u32, tcp_len);

    // TCP header + data
    const words = tcp_len / 2;
    for (0..words) |i| {
        sum +%= (@as(u32, tcp_hdr[i * 2]) << 8) | @as(u32, tcp_hdr[i * 2 + 1]);
    }
    if (tcp_len % 2 == 1) {
        sum +%= @as(u32, tcp_hdr[tcp_len - 1]) << 8;
    }

    // Fold
    while (sum > 0xFFFF) {
        const carry = sum >> 16;
        sum = (sum & 0xFFFF) + carry;
        if (carry == 0) break;
    }
    return @truncate(~sum);
}

// ─── Incoming Packet Handling ─────────────────────────────────────────────

/// Called from net/mod.zig when an IPv4 packet with protocol=6 is received.
/// Handle an incoming SYN for a listening socket.
/// Creates a new TCB in SYN_RECEIVED state, sends SYN-ACK,
/// and queues it in the listen backlog.
fn handleIncomingSyn(src_ip: [4]u8, src_port: u16, dst_port: u16, seq_num: u32, _w: u16) void {
    _ = _w;
    // Find listen slot for this port
    var slot: ?*ListenSlot = null;
    for (0..MAX_CONNECTIONS) |i| {
        if (listen_slots[i].active and listen_slots[i].local_port == dst_port) {
            slot = &listen_slots[i];
            break;
        }
    }
    const ls = slot orelse return;

    // Check backlog capacity
    if (ls.pending_count >= LISTEN_BACKLOG) return;

    // Allocate a new TCB for this connection
    const new_tcb = allocTcb() orelse return;
    new_tcb.local_port = dst_port;
    new_tcb.remote_port = src_port;
    new_tcb.remote_ip = src_ip;
    new_tcb.owner_task = ls.owner_task;
    new_tcb.iss = generateIss();
    new_tcb.snd_una = new_tcb.iss;
    new_tcb.snd_nxt = new_tcb.iss;
    new_tcb.snd_wnd = TCP_WINDOW;
    new_tcb.irs = seq_num;
    new_tcb.rcv_nxt = seq_num + 1;
    new_tcb.rcv_wnd = TCP_WINDOW;
    new_tcb.state = .syn_received;

    // Send SYN-ACK
    _ = sendSegment(new_tcb, SYN | ACK, undefined, 0);
    serial.writeString("[tcp] SYN-ACK sent for incoming connection\n");

    // Find the index of the new TCB
    var new_idx: u32 = 0;
    for (0..MAX_CONNECTIONS) |i| {
        if (&tcbs[i] == new_tcb) {
            new_idx = @intCast(i);
            break;
        }
    }

    // Queue in listen backlog (will be moved to established when ACK arrives)
    ls.pending_tpbs[ls.pending_count] = new_idx;
    ls.pending_count += 1;
}

pub fn handlePacket(src_ip: [4]u8, dst_ip: [4]u8, data: [*]const u8, len: u32) void {
    _ = dst_ip;
    if (len < 20) return;

    // Parse TCP header
    const src_port = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
    const dst_port = (@as(u16, data[2]) << 8) | @as(u16, data[3]);
    const seq_num = (@as(u32, data[4]) << 24) | (@as(u32, data[5]) << 16) |
        (@as(u32, data[6]) << 8) | @as(u32, data[7]);
    const ack_num = (@as(u32, data[8]) << 24) | (@as(u32, data[9]) << 16) |
        (@as(u32, data[10]) << 8) | @as(u32, data[11]);
    const data_offset = (@as(u16, data[12]) >> 4) * 4;
    const flags = data[13];
    const window = (@as(u16, data[14]) << 8) | @as(u16, data[15]);

    if (data_offset < 20 or data_offset > len) return;

    const payload_offset = data_offset;
    const payload_len: u32 = if (len > data_offset) len - data_offset else 0;

    // Find matching TCB
    const tcb = findTcbByTuple(dst_port, src_port, src_ip) orelse {
        // No matching connection — check if any socket is listening on this port
        if (flags & SYN != 0) {
            handleIncomingSyn(src_ip, src_port, dst_port, seq_num, window);
        }
        // Otherwise send RST (or just ignore)
        return;
    };

    // State machine processing
    switch (tcb.state) {
        .syn_sent => {
            if (flags & (SYN | ACK) == (SYN | ACK)) {
                // SYN-ACK received — handshake complete
                tcb.irs = seq_num;
                tcb.rcv_nxt = seq_num + 1;
                tcb.snd_una = ack_num;
                tcb.snd_wnd = window;
                tcb.state = .established;

                // Send ACK to complete handshake
                _ = sendSegment(tcb, ACK, undefined, 0);

                serial.writeString("[tcp] connection established\n");
            } else if (flags & SYN != 0) {
                // Simultaneous open — not supported, send RST
            }
        },
        .syn_received => {
            // Third ACK of three-way handshake (from client)
            if (flags & ACK != 0) {
                tcb.snd_una = ack_num;
                tcb.snd_wnd = window;
                tcb.state = .established;
                tcb.retransmit_timer = 0;
                serial.writeString("[tcp] server: connection established (ACK received)\n");
            }
        },
        .established => {
            // Process ACK
            if (flags & ACK != 0) {
                if (ack_num != tcb.snd_una) {
                    // New ACK — advance send window
                    const acked = ack_num -% tcb.snd_una;
                    if (acked <= SEND_BUF_SIZE) {
                        tcb.snd_una = ack_num;
                        tcb.send_unacked = (tcb.send_unacked + acked) % SEND_BUF_SIZE;
                        tcb.retransmit_timer = 0;
                        tcb.retransmit_count = 0;
                    }
                }
                tcb.snd_wnd = window;
            }

            // Process incoming data
            if (payload_len > 0) {
                processIncomingData(tcb, data + payload_offset, payload_len, seq_num);
            }

            // Handle FIN
            if (flags & FIN != 0) {
                tcb.rcv_nxt +%= 1; // FIN consumes one seq number
                tcb.state = .close_wait;
                _ = sendSegment(tcb, ACK, undefined, 0);
                serial.writeString("[tcp] remote closed (FIN received)\n");
            }
        },
        .fin_wait_1 => {
            if (flags & FIN != 0) {
                // Simultaneous close or ACK+FIN
                tcb.rcv_nxt +%= 1;
                if (flags & ACK != 0) {
                    tcb.snd_una = ack_num;
                }
                tcb.state = .time_wait;
                _ = sendSegment(tcb, ACK, undefined, 0);
                serial.writeString("[tcp] simultaneous close → TIME_WAIT\n");
            } else if (flags & ACK != 0) {
                tcb.snd_una = ack_num;
                tcb.state = .fin_wait_2;
                serial.writeString("[tcp] FIN-ACK received → FIN_WAIT_2\n");
            }
        },
        .fin_wait_2 => {
            if (payload_len > 0) {
                processIncomingData(tcb, data + payload_offset, payload_len, seq_num);
            }
            if (flags & FIN != 0) {
                tcb.rcv_nxt +%= 1;
                tcb.state = .time_wait;
                _ = sendSegment(tcb, ACK, undefined, 0);
                serial.writeString("[tcp] FIN received → TIME_WAIT\n");
            }
        },
        .last_ack => {
            if (flags & ACK != 0) {
                tcb.state = .closed;
                tcb.active = false;
                serial.writeString("[tcp] LAST_ACK → CLOSED\n");
            }
        },
        .close_wait => {
            // Already in close_wait, waiting for app to close
            if (payload_len > 0) {
                processIncomingData(tcb, data + payload_offset, payload_len, seq_num);
            }
        },
        .closing => {
            if (flags & ACK != 0) {
                tcb.state = .time_wait;
                serial.writeString("[tcp] CLOSING → TIME_WAIT\n");
            }
        },
        .time_wait => {
            // Retransmitted FIN — re-ACK
            if (flags & FIN != 0) {
                _ = sendSegment(tcb, ACK, undefined, 0);
            }
        },
        else => {
            // Ignore packets in other states
        },
    }
}

fn processIncomingData(tcb: *TcpTcb, data: [*]const u8, len: u32, seq: u32) void {
    // Check if this is the expected sequence
    if (seq != tcb.rcv_nxt) {
        // Out-of-order — not supported, just ACK with expected seq
        _ = sendSegment(tcb, ACK, undefined, 0);
        return;
    }

    // Copy to receive ring buffer
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const next_tail = (tcb.recv_tail + 1) % RECV_BUF_SIZE;
        if (next_tail == tcb.recv_head) break; // buffer full
        tcb.recv_buf[tcb.recv_tail] = data[i];
        tcb.recv_tail = next_tail;
    }

    tcb.rcv_nxt +%= len;
    tcb.rcv_wnd = TCP_WINDOW - ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);

    // Send ACK
    _ = sendSegment(tcb, ACK, undefined, 0);
}

// ─── Public API (called from syscalls) ────────────────────────────────────

/// Create a new TCP connection (client connect).
/// Returns tcb index (0-based) or -1 on error.
pub fn tcpConnect(remote_ip: [4]u8, remote_port: u16, owner_task: u32) i64 {
    const tcb = allocTcb() orelse return -1;

    tcb.local_port = allocEphemeralPort();
    tcb.remote_port = remote_port;
    tcb.remote_ip = remote_ip;
    tcb.owner_task = owner_task;
    tcb.iss = generateIss();
    tcb.snd_una = tcb.iss;
    tcb.snd_nxt = tcb.iss;
    tcb.snd_wnd = TCP_WINDOW;
    tcb.rcv_nxt = 0;
    tcb.rcv_wnd = TCP_WINDOW;
    tcb.state = .syn_sent;

    // Send SYN
    if (!sendSegment(tcb, SYN, undefined, 0)) {
        tcb.active = false;
        return -1;
    }

    serial.writeString("[tcp] SYN sent\n");

    // Return the index
    for (0..MAX_CONNECTIONS) |i| {
        if (&tcbs[i] == tcb) return @intCast(i);
    }
    return -1;
}

/// Poll for connection state. Returns:
///  0 = still connecting
///  1 = established
/// -1 = error / closed
pub fn tcpPoll(tcb_idx: u32) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;
    return switch (tcb.state) {
        .established => 1,
        .closed => -1,
        else => 0,
    };
}

/// Send data on an established connection.
/// Returns number of bytes queued, or -1 on error.
pub fn tcpSend(tcb_idx: u32, data: [*]const u8, len: u32) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .established) return -1;

    // Copy data to send ring buffer
    var queued: u32 = 0;
    while (queued < len) {
        const next_tail = (tcb.send_tail + 1) % SEND_BUF_SIZE;
        if (next_tail == tcb.send_head) break;
        tcb.send_buf[tcb.send_tail] = data[queued];
        tcb.send_tail = next_tail;
        queued += 1;
    }

    // Send as much as we can from the buffer
    flushSendBuffer(tcb);

    return queued;
}

/// Flush pending send data as TCP segments.
fn flushSendBuffer(tcb: *TcpTcb) void {
    while (true) {
        const pending = ringDataLen(tcb.send_unacked, tcb.send_tail, SEND_BUF_SIZE);
        const in_flight = tcb.snd_nxt -% tcb.snd_una;
        const window_avail = if (tcb.snd_wnd > in_flight) tcb.snd_wnd - in_flight else 0;
        const can_send = @min(pending, window_avail, TCP_MSS);

        if (can_send == 0) break;

        // Collect data from ring buffer
        var seg_buf: [TCP_MSS]u8 = undefined;
        var pos = tcb.send_unacked;
        var i: u32 = 0;
        while (i < can_send) : (i += 1) {
            seg_buf[i] = tcb.send_buf[pos];
            pos = (pos + 1) % SEND_BUF_SIZE;
        }

        // Advance send pointer before sending (sendSegment updates snd_nxt)
        tcb.send_unacked = pos;
        _ = sendSegment(tcb, ACK | PSH, &seg_buf, @intCast(can_send));
    }
}

/// Receive data from an established connection.
/// Returns number of bytes read, 0 if none available, -1 on error/closed.
pub fn tcpRecv(tcb_idx: u32, buf: [*]u8, len: u32) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;
    if (tcb.state == .closed) return -1;

    const available = ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);
    if (available == 0) {
        if (tcb.state == .close_wait) return -1; // connection closed by remote
        return 0;
    }

    const to_read = @min(available, len);
    var i: u32 = 0;
    while (i < to_read) : (i += 1) {
        buf[i] = tcb.recv_buf[tcb.recv_head];
        tcb.recv_head = (tcb.recv_head + 1) % RECV_BUF_SIZE;
    }

    tcb.rcv_wnd = TCP_WINDOW - ringDataLen(tcb.recv_head, tcb.recv_tail, RECV_BUF_SIZE);

    return @intCast(to_read);
}

/// Close a TCP connection (initiates four-way close).
pub fn tcpClose(tcb_idx: u32) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active) return -1;

    switch (tcb.state) {
        .established => {
            tcb.state = .fin_wait_1;
            _ = sendSegment(tcb, FIN | ACK, undefined, 0);
            serial.writeString("[tcp] FIN sent → FIN_WAIT_1\n");
        },
        .close_wait => {
            tcb.state = .last_ack;
            _ = sendSegment(tcb, FIN | ACK, undefined, 0);
            serial.writeString("[tcp] FIN sent → LAST_ACK\n");
        },
        else => {
            tcb.state = .closed;
            tcb.active = false;
        },
    }
    return 0;
}

/// Get TCP connection state as integer.
pub fn tcpState(tcb_idx: u32) u8 {
    if (tcb_idx >= MAX_CONNECTIONS) return 0;
    if (!tcbs[tcb_idx].active) return 0;
    return @intFromEnum(tcbs[tcb_idx].state);
}

/// Check if connection is established.
pub fn isEstablished(tcb_idx: u32) bool {
    if (tcb_idx >= MAX_CONNECTIONS) return false;
    return tcbs[tcb_idx].active and tcbs[tcb_idx].state == .established;
}

/// Check if connection is fully closed.
pub fn isClosed(tcb_idx: u32) bool {
    if (tcb_idx >= MAX_CONNECTIONS) return true;
    return !tcbs[tcb_idx].active or tcbs[tcb_idx].state == .closed;
}

/// Timer tick — called periodically to handle retransmission.
pub fn timerTick(ms_elapsed: u32) void {
    for (0..MAX_CONNECTIONS) |i| {
        const tcb = &tcbs[i];
        if (!tcb.active) continue;
        if (tcb.state == .closed or tcb.state == .time_wait) {
            // Clean up TIME_WAIT after 30 seconds
            if (tcb.state == .time_wait) {
                tcb.retransmit_timer +%= ms_elapsed;
                if (tcb.retransmit_timer >= 30000) {
                    tcb.state = .closed;
                    tcb.active = false;
                    serial.writeString("[tcp] TIME_WAIT → CLOSED (timeout)\n");
                }
            }
            continue;
        }

        // Check for unacknowledged data
        if (tcb.snd_nxt != tcb.snd_una) {
            tcb.retransmit_timer +%= ms_elapsed;
            if (tcb.retransmit_timer >= RETRANSMIT_MS) {
                tcb.retransmit_timer = 0;
                tcb.retransmit_count += 1;
                if (tcb.retransmit_count > 5) {
                    // Give up
                    serial.writeString("[tcp] retransmit timeout, closing\n");
                    tcb.state = .closed;
                    tcb.active = false;
                    continue;
                }
                // Retransmit: reset snd_nxt back to snd_una and re-flush
                tcb.snd_nxt = tcb.snd_una;
                // Reset send_unacked to send_head to resend buffered data
                const unacked = tcb.send_tail -% tcb.send_head;
                if (unacked > 0 and unacked <= SEND_BUF_SIZE) {
                    // Re-send from beginning of pending data
                    tcb.send_unacked = tcb.send_head;
                    flushSendBuffer(tcb);
                } else if (tcb.state == .syn_sent) {
                    // Retransmit SYN
                    _ = sendSegment(tcb, SYN, undefined, 0);
                } else if (tcb.state == .fin_wait_1 or tcb.state == .last_ack) {
                    // Retransmit FIN
                    _ = sendSegment(tcb, FIN | ACK, undefined, 0);
                }
                serial.writeString("[tcp] retransmit\n");
            }
        }
    }
}

// ─── Listening / Server Socket Support ──────────────────────────────────────

const LISTEN_BACKLOG: u32 = 4;

const ListenSlot = struct {
    active: bool = false,
    local_port: u16 = 0,
    owner_task: u32 = 0,
    pending_tpbs: [LISTEN_BACKLOG]u32, // TCB indices of pending connections (SYN_RECEIVED)
    pending_count: u32 = 0,
};

var listen_slots: [MAX_CONNECTIONS]ListenSlot = @splat(.{
    .active = false,
    .local_port = 0,
    .owner_task = 0,
    .pending_tpbs = @splat(0),
    .pending_count = 0,
});

/// Create a TCP socket (allocate a TCB in closed state).
/// Returns TCB index (>= 0) on success, -1 on failure.
pub fn tcpSocket(owner_task: u32) i64 {
    const tcb = allocTcb() orelse return -1;
    tcb.owner_task = owner_task;
    tcb.state = .closed;

    // Return index
    for (0..MAX_CONNECTIONS) |i| {
        if (&tcbs[i] == tcb) return @intCast(i);
    }
    return -1;
}

/// Bind a TCB to a local port.
/// Returns 0 on success, -1 on failure.
pub fn tcpBind(tcb_idx: u32, port: u16) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .closed) return -1;

    // Check if port is already in use
    if (findTcbByLocalPort(port) != null) return -1;

    tcb.local_port = port;
    return 0;
}

/// Start listening for connections on a bound TCB.
/// Returns 0 on success, -1 on failure.
pub fn tcpListen(tcb_idx: u32) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.local_port == 0) return -1;

    tcb.state = .listen;

    // Set up listen slot for incoming SYN tracking
    for (0..MAX_CONNECTIONS) |i| {
        if (!listen_slots[i].active) {
            listen_slots[i].active = true;
            listen_slots[i].local_port = tcb.local_port;
            listen_slots[i].owner_task = tcb.owner_task;
            listen_slots[i].pending_count = 0;
            listen_slots[i].pending_tpbs = @splat(0);
            return 0;
        }
    }
    return -1;
}

/// Accept a pending connection on a listening socket.
/// Returns new TCB index (>= 0) for the accepted connection, -1 if none pending.
pub fn tcpAccept(tcb_idx: u32, owner_task: u32) i64 {
    if (tcb_idx >= MAX_CONNECTIONS) return -1;
    const tcb = &tcbs[tcb_idx];
    if (!tcb.active or tcb.state != .listen) return -1;

    // Find the listen slot for this TCB
    var slot: ?*ListenSlot = null;
    for (0..MAX_CONNECTIONS) |i| {
        if (listen_slots[i].active and listen_slots[i].local_port == tcb.local_port) {
            slot = &listen_slots[i];
            break;
        }
    }
    const ls = slot orelse return -1;

    if (ls.pending_count == 0) return 0; // No pending connections

    // Get the first pending TCB
    const pending_idx = ls.pending_tpbs[0];

    // Shift the queue
    var j: u32 = 0;
    while (j < ls.pending_count - 1) : (j += 1) {
        ls.pending_tpbs[j] = ls.pending_tpbs[j + 1];
    }
    ls.pending_count -= 1;

    if (pending_idx >= MAX_CONNECTIONS) return -1;
    const new_tcb = &tcbs[pending_idx];
    if (!new_tcb.active or new_tcb.state != .established) return -1;

    // Transfer ownership to the accepting task
    new_tcb.owner_task = owner_task;

    return @intCast(pending_idx);
}

/// Get the TCB index for a socket fd.
pub fn getTcbIdx(tcb_idx: u32) ?u32 {
    if (tcb_idx >= MAX_CONNECTIONS) return null;
    if (!tcbs[tcb_idx].active) return null;
    return tcb_idx;
}
