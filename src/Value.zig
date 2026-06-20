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

/// Asserts the value is an integer and it fits in a i64
pub fn toSignedInt(val: Value, ip: *InternPool) i64 {
    return switch (val.toIntern()) {
        else => switch (ip.indexToKey(val.toIntern())) {
            .number => |x| @intCast(x),
            else => unreachable,
        },
    };
}
