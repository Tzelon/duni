//! Both types and values are canonically represented by a single 32-bit integer
//! which is an index into an `InternPool` data structure.
//! This struct abstracts around this storage by providing methods only
//! applicable to comptime-known values rather than types or other interned entities.

const Value = @This();

const std = @import("std");
const assert = std.debug.assert;

const InternPool = @import("InternPool.zig");

ip_index: InternPool.Index,

pub fn fromInterned(i: InternPool.Index) Value {
    assert(i != .none);
    return .{ .ip_index = i };
}

pub fn toIntern(val: Value) InternPool.Index {
    assert(val.ip_index != .none);
    return val.ip_index;
}

/// Asserts the value is an integer `number`. Integers are always stored within
/// `i64` range, so this never truncates.
pub fn toSignedInt(val: Value, ip: *InternPool) i64 {
    return switch (ip.indexToKey(val.toIntern())) {
        .number => |num| switch (num.storage) {
            .int => |int_value| int_value,
            .float => unreachable,
        },
        else => unreachable,
    };
}

/// Returns the value as `f64`, asserting it is a `number`. Integer operands are
/// lifted via `@floatFromInt`; this is how division promotes ints to floats.
pub fn toFloat(val: Value, ip: *InternPool) f64 {
    return switch (ip.indexToKey(val.toIntern())) {
        .number => |num| switch (num.storage) {
            .int => |int_value| @floatFromInt(int_value),
            .float => |float_value| float_value,
        },
        else => unreachable,
    };
}
