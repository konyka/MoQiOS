//! SK-156 — forking must not make a read-only page writable.
//!
//! The clone paths ran every present entry through `cowPte`, which clears the
//! write bit and sets the COW marker. On a page that was already read-only that
//! marker is a lie: it is the only thing the fault handler looks at, and it
//! answers by granting write access. So the first write to a forked child's
//! text, rodata or PROT_READ page un-shared it *and made it writable*, quietly
//! lifting the protection the parent had.
//!
//! `sharedPte` marks only writable pages, leaving read-only ones untouched.

const builtin = @import("builtin");
const arch = @import("../arch/arch.zig");
const cow_pte = @import("../mm/cow_pte.zig");

const PRESENT: u64 = 1 << 0;
const WRITABLE: u64 = 1 << 1;
const USER: u64 = 1 << 2;
const COW: u64 = 1 << 9;
const NX: u64 = 1 << 63;

const FRAME: u64 = 0x0000_0000_0030_B000;

fn fail(msg: []const u8) void {
    arch.serial.writeString("[SK-156] FAILED: ");
    arch.serial.writeString(msg);
    arch.serial.writeString("\n");
}

pub fn announce() void {
    // A writable page is downgraded and marked, so the next write faults.
    const rw = PRESENT | WRITABLE | USER | NX | FRAME;
    const rw_shared = cow_pte.sharedPte(rw);
    if (rw_shared & WRITABLE != 0) {
        fail("writable page kept its write bit");
        return;
    }
    if (!cow_pte.isCow(rw_shared)) {
        fail("writable page not marked COW");
        return;
    }

    // A read-only page is shared exactly as it stands. Marking it COW would let
    // the fault handler hand the child write access the parent never had.
    const ro = PRESENT | USER | NX | FRAME;
    const ro_shared = cow_pte.sharedPte(ro);
    if (ro_shared != ro) {
        fail("read-only page was altered");
        return;
    }
    if (cow_pte.isCow(ro_shared)) {
        fail("read-only page marked COW");
        return;
    }

    // Read-only and executable — a text page. Same rule, and NX must stay clear.
    const text = PRESENT | USER | FRAME;
    const text_shared = cow_pte.sharedPte(text);
    if (text_shared != text) {
        fail("text page was altered");
        return;
    }

    // NX survives the downgrade; rebuilding an entry from its parts used to
    // drop bit 63 and hand the child an executable stack.
    if (rw_shared & NX == 0) {
        fail("NX dropped");
        return;
    }
    if (rw_shared & ~(WRITABLE | COW) != rw & ~(WRITABLE | COW)) {
        fail("frame or flags disturbed");
        return;
    }

    // Sharing an already-COW entry is a no-op, so the fork loop can tell from
    // the result alone whether the parent's entry needs rewriting.
    if (cow_pte.sharedPte(rw_shared) != rw_shared) {
        fail("second share was not idempotent");
        return;
    }

    arch.serial.writeString("[SK-156] fork keeps read-only pages read-only non-x86: OK\n");
}
