//! Both types and values are canonically represented by a single 32-bit integer
//! which is an index into an `InternPool` data structure.
//! This struct abstracts around this storage by providing methods only
//! applicable to types rather than values in general.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig");
const assert = std.debug.assert;
const log = std.log.scoped(.Type);
const InternPool = @import("InternPool.zig");
const Type = @This();

ip_index: InternPool.Index,

pub fn fromInterned(i: InternPool.Index) Type {
    assert(i != .none);
    return .{ .ip_index = i };
}

pub fn toIntern(ty: Type) InternPool.Index {
    assert(ty.ip_index != .none);
    return ty.ip_index;
}

pub fn isNumeric(ty: Type, ip: *const InternPool) bool {
    return switch (ty.toIntern()) {
        .f64_type,
        .u32_type,
        .i32_type,
        .u64_type,
        .i64_type,
        .comptime_int_type,
        .comptime_float_type,
        => true,

        else => switch (ip.indexToKey(ty.toIntern())) {
            else => false,
        },
    };
}

/// Asserts the type is a function or a function pointer.
pub fn fnReturnType(ty: Type, ip: *const InternPool) Type {
    return Type.fromInterned(ip.funcTypeReturnType(ty.toIntern()));
}

pub const @"void": Type = .{ .ip_index = .void_type };
