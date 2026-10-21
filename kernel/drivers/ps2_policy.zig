//! i8042 output-byte ownership (status register 0x64). Pure.
//!
//! The controller has a single output register (0x60) shared by the
//! keyboard and aux (mouse) channels. Status bit 0 (OBF) says a byte is
//! waiting; bit 5 (AUX OBF) says that byte came from the aux channel. Each
//! IRQ handler must only consume bytes of its own channel.

pub const STATUS_OBF: u8 = 0x01;
pub const STATUS_AUX: u8 = 0x20;

pub const Owner = enum { none, keyboard, aux };

pub fn classify(status: u8) Owner {
    if (status & STATUS_OBF == 0) return .none;
    if (status & STATUS_AUX != 0) return .aux;
    return .keyboard;
}

pub const KbdAction = enum {
    /// Nothing to read, or the byte belongs to the live mouse handler.
    ignore,
    /// Keyboard byte: read and decode.
    consume,
    /// Aux byte with no mouse driver armed: read and drop it, otherwise the
    /// full output buffer blocks every later keyboard byte.
    discard,
};

pub fn keyboardAction(status: u8, mouse_present: bool) KbdAction {
    return switch (classify(status)) {
        .none => .ignore,
        .keyboard => .consume,
        .aux => if (mouse_present) .ignore else .discard,
    };
}

pub fn mouseShouldConsume(status: u8) bool {
    return classify(status) == .aux;
}
