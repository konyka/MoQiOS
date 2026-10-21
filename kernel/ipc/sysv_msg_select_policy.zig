/// Pure msgrcv message-selection policy (no arch imports — host testable).
///
/// Every message carries a per-queue monotonically increasing `seq` assigned
/// at msgsnd time. Ring position is NOT a reliable age order: typed receives
/// leave holes that a later msgsnd may back-fill, so selection is by `seq`.
pub const Slot = struct {
    used: bool = false,
    mtype: i64 = 0,
    seq: u64 = 0,
};

/// Pick the slot index msgrcv(msgtyp) must dequeue, or null when none match.
///   msgtyp == 0: the oldest message (smallest seq).
///   msgtyp  > 0: the oldest message whose type == msgtyp.
///   msgtyp  < 0: among messages with type <= |msgtyp|, the lowest type;
///                ties broken by the oldest (smallest seq).
pub fn select(slots: []const Slot, msgtyp: i64) ?usize {
    // |msgtyp| — minInt(i64) has no positive counterpart; clamp to maxInt.
    const abs_type: i64 = if (msgtyp == std.math.minInt(i64))
        std.math.maxInt(i64)
    else if (msgtyp < 0)
        -msgtyp
    else
        msgtyp;
    var best: ?usize = null;
    for (slots, 0..) |s, i| {
        if (!s.used) continue;
        if (msgtyp > 0 and s.mtype != msgtyp) continue;
        if (msgtyp < 0 and s.mtype > abs_type) continue;
        if (best) |b| {
            const cur = slots[b];
            const better = if (msgtyp < 0)
                s.mtype < cur.mtype or (s.mtype == cur.mtype and s.seq < cur.seq)
            else
                s.seq < cur.seq;
            if (!better) continue;
        }
        best = i;
    }
    return best;
}

const std = @import("std");
