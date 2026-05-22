//! Abstract Syntax Tree for Duni source code.
//! For Duni syntax, the root node is at `nodes[0]` and contains the list of
//! sub-nodes.

const std = @import("std");
const Token = @import("scanner.zig").Token;
const Parser = @import("parser.zig").Parser;
const Scanner = @import("scanner.zig").Scanner;
const Ast = @This();

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Reference to externally-owned data.
source: [:0]const u8,

tokens: TokenList.Slice,
/// The root AST node is assumed to be index 0. Since there can be no
/// references to the root node, this means 0 is available to indicate null.
nodes: NodeList.Slice,
extra_data: []u32,
errors: []const Error,

pub const TokenIndex = u32;
pub const ByteOffset = u32;

pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});

pub const NodeList = std.MultiArrayList(Node);

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

pub fn parse(gpa: Allocator, source: [:0]const u8) !Ast {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(gpa);

    // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
    const estimated_token_count = source.len / 8;
    try tokens.ensureTotalCapacity(gpa, estimated_token_count);

    var scanner = Scanner.init(source);

    while (true) {
        const token = scanner.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    var parser: Parser = .{
        .source = source,
        .gpa = gpa,
        .token_tags = tokens.items(.tag),
        .token_starts = tokens.items(.start),
        .errors = .empty,
        .nodes = .empty,
        .extra_data = .empty,
        .scratch = .empty,
        .token_index = 0,
    };

    defer parser.deinit();

    // Empirically, Zig source code has a 2:1 ratio of tokens to AST nodes.
    // Make sure at least 1 so we can use appendAssumeCapacity on the root node below.
    const estimated_node_count = (tokens.len + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    try parser.parse();

    try parser.extra_data.shrinkToLen(gpa);
    try parser.errors.shrinkToLen(gpa);

    return Ast{
        .source = source,
        .tokens = tokens.toOwnedSlice(),
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = parser.extra_data.toOwnedSliceAssert(),
        .errors = parser.errors.toOwnedSliceAssert(),
    };
}

pub fn containerDeclRoot(tree: Ast) Full.ContainerDecl {
    return .{
        .layout_token = null,
        .ast = .{
            .main_token = undefined,
            .enum_token = null,
            .members = tree.rootDecls(),
            .arg = 0,
        },
    };
}

pub fn rootDecls(tree: Ast) []const Node.Index {
    // Root is always index 0.
    const nodes_data = tree.nodes.items(.data);
    return tree.extra_data[nodes_data[0].lhs..nodes_data[0].rhs];
}

/// Index into `extra_data`.
pub const ExtraIndex = enum(u32) {
    _,
};

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: Data,

    /// Index into `nodes`.
    pub const Index = enum(u32) {
        root = 0,
        _,

        pub fn toOptional(i: Index) OptionalIndex {
            const result: OptionalIndex = @enumFromInt(@intFromEnum(i));
            assert(result != .none);
            return result;
        }

        pub fn toOffset(base: Index, destination: Index) Offset {
            const base_i64: i64 = @intFromEnum(base);
            const destination_i64: i64 = @intFromEnum(destination);
            return @enumFromInt(destination_i64 - base_i64);
        }
    };

    /// Index into `nodes`, or null.
    pub const OptionalIndex = enum(u32) {
        root = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }

        pub fn fromOptional(oi: ?Index) OptionalIndex {
            return if (oi) |i| i.toOptional() else .none;
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

    comptime {
        // Goal is to keep this under one byte for efficiency.
        assert(@sizeOf(Tag) == 1);

        if (!std.debug.runtime_safety) {
            assert(@sizeOf(Data) == 8);
        }
    }

    /// Note: The FooComma/FooSemicolon variants exist to ease the implementation of
    /// Ast.lastToken()
    pub const Tag = enum {
        /// sub_list[lhs...rhs]
        root,
        /// Temp Tag
        global_exp,
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
        /// Both lhs and rhs unused.
        string_literal,
        /// Both lhs and rhs unused.
        unreachable_literal,
        /// Both lhs and rhs unused.
        /// Most identifiers will not have explicit AST nodes, however for expressions
        /// which could be one of many different kinds of AST nodes, there will be an
        /// identifier AST node for it.
        identifier,
        /// `fn (a: b, c: d) return_type`.
        ///
        /// The `data` field is a `.extra_and_opt_node`:
        ///   1. a `Node.ExtraIndex` to `FnProto`.
        ///   2. a `Node.OptionalIndex` to the return type expression. Can't be
        ///      `.none` unless a parsing error occured.
        ///
        /// The `main_token` field is the `fn` token.
        ///
        /// Extern function declarations use this tag.
        fn_proto,
        /// Extern function declarations use the fn_proto tags rather than this one.
        ///
        /// The `data` field is a `.node_and_node`:
        ///   1. a `Node.Index` to `fn_proto_*`.
        ///   2. a `Node.Index` to function body block.
        ///
        /// The `main_token` field is the `fn` token.
        fn_decl,
        /// `{a b}`.
        ///
        /// The `data` field is a `.extra_range` that stores a `Node.Index` for
        /// each statement.
        ///
        /// The `main_token` field is the `{` token.
        block,
    };

    /// some nodes have lhs and rhs data attached to them.
    pub const Data = union {
        node: Index,
        token: TokenIndex,
        node_and_node: struct { Index, Index },
        node_and_token: struct { Index, TokenIndex },
        opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
        extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
        extra_range: SubRange,
    };

    pub const SubRange = struct {
        /// Index into extra_data.
        start: ExtraIndex,
        /// Index into extra_data.
        end: ExtraIndex,
    };
};

pub const Error = struct {
    tag: Tag,
    is_note: bool = false,
    /// True if `token` points to the token before the token causing an issue.
    token_is_prev: bool = false,
    token: TokenIndex,
    extra: union { none: void, expected_tag: Token.Tag } = .{ .none = {} },

    pub const Tag = enum { expected_return_type, expected_comma_after_arg, expected_token, expected_expression, expected_semi_or_lbrace, expected_type_expr, expected_comma_after_param, expected_fn };
};

/// Fully assembled AST node information.
/// fetch extra_data when needed
const Full = struct {
    pub const ContainerDecl = struct {
        layout_token: ?TokenIndex,
        ast: Components,

        pub const Components = struct {
            main_token: TokenIndex,
            /// Populated when main_token is Keyword_union.
            enum_token: ?TokenIndex,
            members: []const Node.Index,
            arg: Node.Index,
        };
    };
};
