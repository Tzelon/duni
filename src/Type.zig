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

/// A single tagged u32, the `Air.Inst.Ref` idiom: MSB 0 → an
/// `InternPool.Index` (a ground, interned type); MSB 1 → a `TypeVar.Index`
/// (an unresolved type variable). Not a Zig `union(enum)` — that would grow
/// the handle and break the 8-byte `Air.Inst.Data` budget (`arg` is already
/// `ty + u32`).
repr: u32,

/// Placeholder for the future type-variable store (notes/type_system.md §8).
/// No store or producer exists yet; the index type exists so `Type`'s
/// two-arm representation is installed before the first tvar is made.
pub const TypeVar = struct {
    pub const Index = enum(u31) { _ };
};

pub fn fromInterned(i: InternPool.Index) Type {
    assert(i != .none);
    // The MSB is the tvar tag bit, so an interned index must fit in u31.
    // (`InternPool.Index.none` is maxInt(u32) and is rejected above.)
    assert(@intFromEnum(i) >> 31 == 0);
    return .{ .repr = @intFromEnum(i) };
}

/// Asserts the type is interned, not a type variable.
pub fn toIntern(ty: Type) InternPool.Index {
    assert(!ty.isTvar());
    return @enumFromInt(ty.repr);
}

pub fn fromTvar(i: TypeVar.Index) Type {
    return .{ .repr = @as(u32, 1 << 31) | @intFromEnum(i) };
}

/// Asserts the type is a type variable.
pub fn toTvar(ty: Type) TypeVar.Index {
    assert(ty.isTvar());
    return @enumFromInt(@as(u31, @truncate(ty.repr)));
}

pub fn isTvar(ty: Type) bool {
    return ty.repr >> 31 != 0;
}

pub fn unwrap(ty: Type) union(enum) { interned: InternPool.Index, tvar: TypeVar.Index } {
    return if (ty.isTvar())
        .{ .tvar = @enumFromInt(@as(u31, @truncate(ty.repr))) }
    else
        .{ .interned = @enumFromInt(ty.repr) };
}

/// The user-visible name of the type, for diagnostics. `f64` renders as
/// `number` — that is the name the language exposes.
pub fn name(ty: Type) []const u8 {
    return switch (ty.toIntern()) {
        .comptime_int_type => "comptime_int",
        .comptime_float_type => "comptime_float",
        .f64_type => "number",
        .u32_type => "u32",
        .i32_type => "i32",
        .u64_type => "u64",
        .i64_type => "i64",
        .string_type => "string",
        .void_type => "void",
        .type_type => "type",
        else => "(unnamed type)",
    };
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

/// Asserts the type is a fixed-size float or comptime_float.
/// Returns 128 for comptime_float types.
pub fn floatBits(ty: Type) u16 {
    return switch (ty.toIntern()) {
        .f32_type => 32,
        .f64_type => 64,
        .comptime_float_type => 64,

        else => unreachable,
    };
}

pub const @"void": Type = .fromInterned(.void_type);

test "Type stays a 4-byte handle" {
    // The 8-byte `Air.Inst.Data` budget depends on it (`arg` is ty + u32).
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Type));
}

test "interned arm round-trips" {
    const ty: Type = .fromInterned(.f64_type);
    try std.testing.expectEqual(InternPool.Index.f64_type, ty.toIntern());
    try std.testing.expect(!ty.isTvar());
    try std.testing.expectEqual(InternPool.Index.f64_type, ty.unwrap().interned);
}

test "tvar arm round-trips" {
    const tvar_index: TypeVar.Index = @enumFromInt(7);
    const ty: Type = .fromTvar(tvar_index);
    try std.testing.expect(ty.isTvar());
    try std.testing.expectEqual(tvar_index, ty.toTvar());
    try std.testing.expectEqual(tvar_index, ty.unwrap().tvar);
}
