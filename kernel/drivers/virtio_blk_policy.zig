//! Pure virtio-blk feature/request constants and negotiation (host-tested).

/// VIRTIO_BLK_F_FLUSH: the device has a volatile write cache and accepts
/// VIRTIO_BLK_T_FLUSH. Without it writes are durable on completion.
pub const F_FLUSH: u32 = 1 << 9;
pub const F_DISCARD: u32 = 1 << 13;

pub const T_IN: u32 = 0;
pub const T_OUT: u32 = 1;
pub const T_FLUSH: u32 = 4;
pub const T_DISCARD: u32 = 8;

/// Driver feature bits for what the device offers: exactly DISCARD and
/// FLUSH, nothing else (legacy register, bits 0-31).
pub fn negotiate(device_features: u32) u32 {
    return device_features & (F_FLUSH | F_DISCARD);
}
