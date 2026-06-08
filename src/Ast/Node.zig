const TokenIndex = @import("../Ast.zig").TokenIndex;

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
};

pub const Data = union {
    node: Index,
    token: TokenIndex,
};

pub const Index = enum(u32) {
    root = 0,
    _,
};
