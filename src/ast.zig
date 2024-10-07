const std = @import("std");
const Token = @import("./scanner.zig").Token;

const assert = std.debug.assert;

pub const TokenIndex = u32;
pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    pub const Index = u32;

    comptime {
        // Goal is to keep this under one byte for efficiency.
        assert(@sizeOf(Tag) == 1);
    }

    /// Note: The FooComma/FooSemicolon variants exist to ease the implementation of
    /// Ast.lastToken()
    pub const Tag = enum {
        //TODO(tzelon): what does it means? https://github.com/ziglang/zig/blob/be5378b03805fa95b3cf36b6727d2c364c155e64/lib/std/zig/Ast.zig#L3016C7-L3017C14
        /// sub_list[lhs...rhs]
        root,
        /// `lhs + rhs`. main_token is the `+`.
        add,
        /// `lhs - rhs`. main_token is the `-`.
        sub,
        /// `lhs * rhs`. main_token is the `*`.
        mul,
        /// `lhs / rhs`. main_token is the `/`.
        div,
        /// `lhs == rhs`. main_token is op.
        equal_equal,
        /// `lhs != rhs`. main_token is op.
        bang_equal,
        /// `lhs < rhs`. main_token is op.
        less_than,
        /// `lhs > rhs`. main_token is op.
        greater_than,
        /// `lhs <= rhs`. main_token is op.
        less_or_equal,
        /// `lhs >= rhs`. main_token is op.
        greater_or_equal,
        /// `lhs *= rhs`. main_token is op.
        assign_mul,
        /// `lhs /= rhs`. main_token is op.
        assign_div,
        /// `lhs %= rhs`. main_token is op.
        assign_mod,
        /// `lhs += rhs`. main_token is op.
        assign_add,
        /// `lhs -= rhs`. main_token is op.
        assign_sub,
        /// `op lhs`. rhs unused. main_token is op.
        bool_not,
        /// `op lhs`. rhs unused. main_token is op.
        negation,
        /// `(lhs)`. main_token is the `(`; rhs is the token index of the `)`.
        grouped_expression,
        /// Both lhs and rhs unused.
        number_literal,
    };

    pub const Data = struct {
        lhs: Index,
        rhs: Index,
    };
};
