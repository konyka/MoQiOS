//! Pure validation for mq_open creation attributes.

pub const Validation = enum {
    defaults,
    valid,
    invalid,
};

pub fn validate(create_requested: bool, present: bool, max_messages: i64, message_size: i64, max_supported_messages: u32, max_supported_size: u32) Validation {
    if (!create_requested or !present) return .defaults;
    if (max_messages <= 0 or message_size <= 0) return .invalid;
    if (max_messages > max_supported_messages or message_size > max_supported_size) return .invalid;
    return .valid;
}

test "mq_open creation attributes must fit implementation limits" {
    const std = @import("std");
    try std.testing.expectEqual(Validation.defaults, validate(false, true, 0, 0, 8, 512));
    try std.testing.expectEqual(Validation.defaults, validate(true, false, 0, 0, 8, 512));
    try std.testing.expectEqual(Validation.valid, validate(true, true, 8, 512, 8, 512));
    try std.testing.expectEqual(Validation.invalid, validate(true, true, 0, 512, 8, 512));
    try std.testing.expectEqual(Validation.invalid, validate(true, true, 8, 513, 8, 512));
}
