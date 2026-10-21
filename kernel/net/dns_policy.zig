//! DNS response acceptance (anti-spoofing). Pure: no arch/udp imports.
//!
//! A response is only considered when it comes from the exact server and
//! port the query was sent to and echoes the query's (random) ID.

pub const DNS_PORT: u16 = 53;

pub fn acceptResponse(
    src_ip: [4]u8,
    src_port: u16,
    server_ip: [4]u8,
    resp_id: u16,
    query_id: u16,
) bool {
    if (src_port != DNS_PORT) return false;
    for (src_ip, server_ip) |a, b| {
        if (a != b) return false;
    }
    return resp_id == query_id;
}
