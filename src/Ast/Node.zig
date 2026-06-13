const std = @import("std");
const assert = std.debug.assert;

const TokenIndex = @import("../Ast.zig").TokenIndex;
const NullTerminatedString = @import("../string.zig").NullTerminatedString;

const Node = @This();

tag: Tag,
main_token: TokenIndex,
data: Data,

pub const Tag = enum {
    /// The root node which is guaranteed to be at `Node.Index.root`.
    ///
    /// The `main_token` field is the first token for the source file.
    root,

    /// The `data` field is unused.
    number_literal,
    form,
};

pub const Data = union {
    node: Index,
    token: TokenIndex,
    node_and_token: struct { Index, TokenIndex },

    form: Form,
    extra: ExtraIndex,
};

pub const Index = enum(u32) {
    root = 0,
    _,

    pub fn toOffset(base: Index, destination: Index) Offset {
        const base_i64: i64 = @intFromEnum(base);
        const destination_i64: i64 = @intFromEnum(destination);
        return @enumFromInt(destination_i64 - base_i64);
    }
};

/// A relative node index.
pub const Offset = enum(i32) {
    zero = 0,
    _,

    pub fn toOptional(o: Offset) OptionalOffset {
        const result: OptionalOffset = @enumFromInt(@intFromEnum(o));
        assert(result != .none);
        return result;
    }

    pub fn toAbsolute(offset: Offset, base: Index) Index {
        return @enumFromInt(@as(i64, @intFromEnum(base)) + @intFromEnum(offset));
    }
};

/// A relative node index, or null.
pub const OptionalOffset = enum(i32) {
    none = std.math.maxInt(i32),
    _,

    pub fn unwrap(oo: OptionalOffset) ?Offset {
        return if (oo == .none) null else @enumFromInt(@intFromEnum(oo));
    }
};

pub const ExtraIndex = enum(u32) { _ };

pub const Form = packed struct(u64) {
    op: NullTerminatedString,
    args: ExtraIndex, // offset of SubRange in extra_data
};

pub const SubRange = struct {
    /// Index into extra_data.
    start: ExtraIndex,
    /// Index into extra_data.
    end: ExtraIndex,
};
