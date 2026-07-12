//! Both types and values are canonically represented by a single 32-bit integer
//! which is an index into an `InternPool` data structure.
//! This struct abstracts around this storage by providing methods only
//! applicable to comptime-known values rather than types or other interned entities.

const Value = @This();

const std = @import("std");
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;

const InternPool = @import("InternPool.zig");
pub const BigIntSpace = InternPool.Key.Int.Storage.BigIntSpace;

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
pub fn toSignedInt(val: Value, ip: *const InternPool) i64 {
    return switch (val.toIntern()) {
        else => switch (ip.indexToKey(val.toIntern())) {
            .int => |int| switch (int.storage) {
                .i64 => |x| x,
                .u64 => |x| @intCast(x),
                .big_int => |big_int| big_int.toInt(i64) catch unreachable,
            },
            else => unreachable,
        },
    };
}

/// If the value fits in a u64, return it, otherwise null.
/// Asserts not undefined.
pub fn getUnsignedInt(val: Value, ip: *const InternPool) ?u64 {
    return switch (val.toIntern()) {
        else => switch (ip.indexToKey(val.toIntern())) {
            .int => |int| switch (int.storage) {
                .big_int => |big_int| big_int.toInt(u64) catch null,
                .u64 => |x| x,
                .i64 => |x| std.math.cast(u64, x),
            },
            else => null,
        },
    };
}

/// Asserts that `val` is an integer.
pub fn toBigInt(val: Value, space: *BigIntSpace, ip: *const InternPool) BigIntConst {
    if (val.getUnsignedInt(ip)) |x| {
        return BigIntMutable.init(&space.limbs, x).toConst();
    }
    const int_key = switch (ip.indexToKey(val.toIntern())) {
        .int => |int| int,
        else => unreachable,
    };
    return int_key.storage.toBigInt(space);
}

/// Asserts that the value is a float or an integer.
pub fn toFloat(val: Value, comptime T: type, ip: *const InternPool) T {
    return switch (ip.indexToKey(val.toIntern())) {
        .int => |int| switch (int.storage) {
            .big_int => |big_int| big_int.toFloat(T, .nearest_even)[0],
            inline .u64, .i64 => |x| {
                return @floatFromInt(x);
            },
        },
        .float => |float| switch (float.storage) {
            inline else => |x| @floatCast(x),
        },
        else => unreachable,
    };
}
