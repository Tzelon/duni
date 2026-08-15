//! Analyzed Intermediate Representation.
//!
//! This data is produced by Sema and consumed by codegen.
//! Unlike ZIR where there is one instance for an entire source file, each function
//! gets its own `Air` instance.

const Air = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const InternPool = @import("../InternPool.zig");
const Value = @import("../Value.zig");
const Type = @import("../Type.zig");

instructions: std.MultiArrayList(Inst).Slice,

/// The meaning of this data is determined by `Inst.Tag` value.
/// The first few indexes are reserved. See `ExtraIndex` for the values.
extra: std.ArrayList(u32),

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        /// Return a value from a function.
        /// Uses the `un_op` field.
        ret,

        /// Function call.
        /// Result type is the return type of the function being called.
        /// Uses the `pl_op` field with the `Call` payload. operand is the callee.
        /// Triggers `resolveTypeLayout` on the return type of the callee.
        ///
        /// See `unwrapCall` for a way to load this tag's data.
        call,
    };

    /// The position of an AIR instruction within the `Air` instructions array.
    pub const Index = enum(u32) {
        _,

        pub fn toRef(index: Index) Inst.Ref {
            return @intFromEnum(index);
        }
    };

    /// Either a reference to a value stored in the InternPool, or a reference to an AIR instruction.
    /// The most-significant bit of the value is a tag bit. This bit is 1 if the value represents an
    /// instruction index and 0 if it represents an InternPool index.
    ///
    /// The ref `none` is an exception: it has the tag bit set but refers to the InternPool.
    pub const Ref = enum(u32) {
        comptime_int_type = @intFromEnum(InternPool.Index.comptime_int_type),
        comptime_float_type = @intFromEnum(InternPool.Index.comptime_float_type),
        f64_type = @intFromEnum(InternPool.Index.f64_type),
        string_type = @intFromEnum(InternPool.Index.string_type),
        zero = @intFromEnum(InternPool.Index.zero),
        one = @intFromEnum(InternPool.Index.one),
        negative_one = @intFromEnum(InternPool.Index.negative_one),

        /// This Ref does not correspond to any AIR instruction or constant
        /// value and may instead be used as a sentinel to indicate null.
        none = @intFromEnum(InternPool.Index.none),
        _,

        pub fn toIndex(ref: Ref) ?Index {
            assert(ref != .none);
            return ref.toIndexAllowNone();
        }

        pub fn toIndexAllowNone(ref: Ref) ?Index {
            return switch (ref) {
                .none => null,
                else => if (@intFromEnum(ref) >> 31 != 0)
                    @enumFromInt(@as(u31, @truncate(@intFromEnum(ref))))
                else
                    null,
            };
        }

        pub fn toInterned(ref: Ref) ?InternPool.Index {
            assert(ref != .none);
            return ref.toInternedAllowNone();
        }

        pub fn toInternedAllowNone(ref: Ref) ?InternPool.Index {
            return switch (ref) {
                // Ref.none maps to IP's none sentinel, not optional-null —
                // null is reserved for "this is an Air-inst ref".
                .none => .none,
                else => if (@intFromEnum(ref) >> 31 == 0)
                    @enumFromInt(@as(u31, @truncate(@intFromEnum(ref))))
                else
                    null,
            };
        }

        pub fn fromInterned(ip_index: InternPool.Index) Ref {
            return switch (ip_index) {
                .none => .none,
                else => {
                    assert(@intFromEnum(ip_index) >> 31 == 0);
                    return @enumFromInt(@as(u31, @intCast(@intFromEnum(ip_index))));
                },
            };
        }

        pub fn toType(ref: Ref) Type {
            return .fromInterned(ref.toInterned().?);
        }

        pub fn fromValue(v: Value) Ref {
            return .fromInterned(v.toIntern());
        }

        pub fn fromType(t: Type) Ref {
            return .fromIntern(t.toIntern());
        }
    };

    /// All instructions have an 8-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        un_op: Ref,

        ty: Type,

        pl_op: struct {
            operand: Ref,
            payload: u32,
        },
    };
};

/// Trailing is a list of `Inst.Ref` for every `args_len`.
pub const Call = struct {
    args_len: u32,
};

pub fn internedToRef(ip_index: InternPool.Index) Inst.Ref {
    return .fromInterned(ip_index);
}

pub fn typeOf(air: *const Air, inst: Air.Inst.Ref, ip: *const InternPool) Type {
    if (inst.toInterned()) |ip_index| {
        return .fromInterned(ip.typeOf(ip_index));
    } else {
        return air.typeOfIndex(inst.toIndex().?, ip);
    }
}

pub fn typeOfIndex(air: *const Air, inst: Air.Inst.Index, ip: *const InternPool) Type {
    _ = ip;
    // const datas = air.instructions.items(.data);
    switch (air.instructions.items(.tag)[@intFromEnum(inst)]) {
        // .arg => return datas[@intFromEnum(inst)].arg.ty.toType(),

        .ret,
        => unreachable,
        //
        // .call => {
        //     const callee_ty = air.typeOf(datas[@intFromEnum(inst)].pl_op.operand, ip);
        //     return .fromInterned(ip.funcTypeReturnType(callee_ty.toIntern()));
        // },
    }
}

pub fn deinit(air: *Air, gpa: std.mem.Allocator) void {
    air.instructions.deinit(gpa);
    air.extra.deinit(gpa);
    air.* = undefined;
}
