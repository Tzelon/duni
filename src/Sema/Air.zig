//! Analyzed Intermediate Representation.
//!
//! This data is produced by Sema and consumed by codegen.
//! Unlike ZIR where there is one instance for an entire source file, each function
//! gets its own `Air` instance.

const Air = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {};

    /// The position of an AIR instruction within the `Air` instructions array.
    pub const Index = enum(u32) {
        _,

        pub fn unwrap(index: Index) union(enum) { ref: Inst.Ref, target: u31 } {
            const low_index: u31 = @truncate(@intFromEnum(index));
            return switch (@as(u1, @intCast(@intFromEnum(index) >> 31))) {
                0 => .{ .ref = @enumFromInt(@as(u32, 1 << 31) | low_index) },
                1 => .{ .target = low_index },
            };
        }

        pub fn toRef(index: Index) Inst.Ref {
            return index.unwrap().ref;
        }

        pub fn fromTargetIndex(index: u31) Index {
            return @enumFromInt((1 << 31) | @as(u32, index));
        }

        pub fn toTargetIndex(index: Index) u31 {
            return index.unwrap().target;
        }

        pub fn format(index: Index, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeByte('%');
            switch (index.unwrap()) {
                .ref => {},
                .target => try w.writeByte('t'),
            }
            try w.print("{d}", .{@as(u31, @truncate(@intFromEnum(index)))});
        }
    };

    /// Either a reference to a value stored in the InternPool, or a reference to an AIR instruction.
    /// The most-significant bit of the value is a tag bit. This bit is 1 if the value represents an
    /// instruction index and 0 if it represents an InternPool index.
    ///
    /// The ref `none` is an exception: it has the tag bit set but refers to the InternPool.
    pub const Ref = enum(u32) {
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
    };

    /// All instructions have an 8-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {};
};
