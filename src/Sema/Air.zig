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

instructions: std.MultiArrayList(Inst).Slice,

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        /// Return a value from a function.
        /// Uses the `un_op` field.
        ret,
    };

    /// The position of an AIR instruction within the `Air` instructions array.
    pub const Index = enum(u32) {
        _,
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

        pub fn fromValue(v: Value) Ref {
            return .fromInterned(v.toIntern());
        }
    };

    /// All instructions have an 8-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        un_op: Ref,
    };
};

pub fn internedToRef(ip_index: InternPool.Index) Inst.Ref {
    return .fromInterned(ip_index);
}

pub fn deinit(air: *Air, gpa: std.mem.Allocator) void {
    air.instructions.deinit(gpa);
    air.* = undefined;
}
