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
    form: Form,

    extra: ExtraIndex,
};

pub const Index = enum(u32) {
    root = 0,
    _,
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
