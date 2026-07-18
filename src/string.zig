const std = @import("std");
const assert = std.debug.assert;
const Hash = std.hash.Wyhash;
const Io = std.Io;

const InternPool = @import("InternPool.zig");

/// An index into `strings`.
pub const NullTerminatedString = enum(u32) {
    /// An empty string.
    empty = 0,
    plus = 1,
    minus = 2,
    star = 3,
    slash = 4,
    equal = 5,
    _,

    pub const static_len = @typeInfo(@This()).@"enum".fields.len;

    /// An array of `NullTerminatedString` existing within the `extra` array.
    /// This type exists to provide a struct with lifetime that is
    /// not invalidated when items are added to the `InternPool`.
    pub const Slice = struct {
        start: u32,
        len: u32,

        pub const empty: Slice = .{ .start = 0, .len = 0 };

        pub fn get(slice: Slice, ip: *const InternPool) []NullTerminatedString {
            const extra = ip.extra.items;
            return @ptrCast(extra[slice.start..][0..slice.len]);
        }
    };

    pub fn toOptional(self: NullTerminatedString) OptionalNullTerminatedString {
        return @enumFromInt(@intFromEnum(self));
    }

    pub fn toSlice(string: NullTerminatedString, ip: *const InternPool) [:0]const u8 {
        const index = @intFromEnum(string);
        return ip.string_bytes.items[ip.strings.items[index] .. ip.strings.items[index + 1] - 1 :0];
    }

    pub fn length(string: NullTerminatedString, ip: *const InternPool) u32 {
        const index = @intFromEnum(string);
        return ip.strings.items[index + 1] - 1 - ip.strings.items[index];
    }

    pub fn eqlSlice(string: NullTerminatedString, slice: []const u8, ip: *const InternPool) bool {
        return std.mem.eql(u8, string.toSlice(ip), slice);
    }

    /// Stored-side context. The map holds `NullTerminatedString`, we decode it to bytes to hash/compare.
    pub const Context = struct {
        ip: *const InternPool,
        pub fn hash(ctx: @This(), s: NullTerminatedString) u64 {
            return Hash.hash(0, s.toSlice(ctx.ip));
        }
        pub fn eql(ctx: @This(), a: NullTerminatedString, b: NullTerminatedString) bool {
            _ = ctx;
            return a == b; // same handle == same bytes by construction
        }
    };

    /// Probe-side adapter. Lets us look up a stored `NullTerminatedString` using raw bytes.
    pub const Adapter = struct {
        ip: *const InternPool,
        pub fn hash(_: @This(), bytes: []const u8) u64 {
            return Hash.hash(0, bytes);
        }
        pub fn eql(adpt: @This(), bytes: []const u8, stored: NullTerminatedString) bool {
            return std.mem.eql(u8, bytes, stored.toSlice(adpt.ip));
        }
    };

    /// Compare based on integer value alone, ignoring the string contents.
    pub fn indexLessThan(ctx: void, a: NullTerminatedString, b: NullTerminatedString) bool {
        _ = ctx;
        return @intFromEnum(a) < @intFromEnum(b);
    }

    const FormatData = struct {
        string: NullTerminatedString,
        ip: *const InternPool,
        id: bool,
    };

    fn format(data: FormatData, writer: *Io.Writer) Io.Writer.Error!void {
        const slice = data.string.toSlice(data.ip);
        if (!data.id) {
            try writer.writeAll(slice);
        } else {
            try writer.print("{f}", .{std.zig.fmtIdP(slice)});
        }
    }

    pub fn fmt(string: NullTerminatedString, ip: *const InternPool) std.fmt.Alt(FormatData, format) {
        return .{ .data = .{ .string = string, .ip = ip, .id = false } };
    }

    pub fn fmtId(string: NullTerminatedString, ip: *const InternPool) std.fmt.Alt(FormatData, format) {
        return .{ .data = .{ .string = string, .ip = ip, .id = true } };
    }
};

/// An index into `strings` which might be `none`.
pub const OptionalNullTerminatedString = enum(u32) {
    /// This is distinct from `none` - it is a valid index that represents empty string.
    empty = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(string: OptionalNullTerminatedString) ?NullTerminatedString {
        return if (string != .none) @enumFromInt(@intFromEnum(string)) else null;
    }

    pub fn toSlice(string: OptionalNullTerminatedString, ip: *const InternPool) ?[:0]const u8 {
        return (string.unwrap() orelse return null).toSlice(ip);
    }
};

pub const static_strings: [NullTerminatedString.static_len][]const u8 = .{
    "",
    "+",
    "-",
    "*",
    "/",
    "=",
};
