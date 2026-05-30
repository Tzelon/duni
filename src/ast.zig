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

pub const ByteOffset = u32;

/// Index into `tokens`.
pub const TokenIndex = u32;
pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});
/// Index into `tokens`, or null.
pub const OptionalTokenIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oti: OptionalTokenIndex) ?TokenIndex {
        return if (oti == .none) null else @intFromEnum(oti);
    }

    pub fn fromToken(ti: TokenIndex) OptionalTokenIndex {
        return @enumFromInt(ti);
    }

    pub fn fromOptional(oti: ?TokenIndex) OptionalTokenIndex {
        return if (oti) |ti| @enumFromInt(ti) else .none;
    }
};

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

pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
    const token_tag = tree.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var tokenizer: std.zig.Tokenizer = .{
        .buffer = tree.source,
        .index = tree.tokenStart(token_index),
    };
    const token = tokenizer.next();
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn extraDataSlice(tree: Ast, range: Node.SubRange, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

pub fn extraDataSliceWithLen(tree: Ast, start: ExtraIndex, len: u32, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@intFromEnum(start)..][0..len]);
}

pub fn extraData(tree: Ast, index: ExtraIndex, comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
        @field(result, field_name) = switch (field_type) {
            Node.Index,
            Node.OptionalIndex,
            OptionalTokenIndex,
            ExtraIndex,
            => @enumFromInt(tree.extra_data[@intFromEnum(index) + i]),
            TokenIndex => tree.extra_data[@intFromEnum(index) + i],
            else => @compileError("unexpected field type: " ++ @typeName(field_type)),
        };
    }
    return result;
}

pub fn containerDeclRoot(tree: Ast) full.ContainerDecl {
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

pub fn nodeTag(self: *const Ast, node: Node.Index) Node.Tag {
    return self.nodes.items(.tag)[@intFromEnum(node)];
}

pub fn nodeData(self: *const Ast, node: Node.Index) Node.Data {
    return self.nodes.items(.data)[@intFromEnum(node)];
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
        /// `lhs * rhs`. The `main_token` field is the `*` token.
        mul,
        /// `lhs / rhs`. The `main_token` field is the `/` token.
        div,
        /// `lhs % rhs`. The `main_token` field is the `%` token.
        mod,
        /// `lhs + rhs`. The `main_token` field is the `+` token.
        add,
        /// `lhs - rhs`. The `main_token` field is the `-` token.
        sub,
        /// `lhs == rhs`. The `main_token` field is the `==` token.
        equal_equal,
        /// `lhs != rhs`. The `main_token` field is the `!=` token.
        bang_equal,
        /// `lhs < rhs`. The `main_token` field is the `<` token.
        less_than,
        /// `lhs > rhs`. The `main_token` field is the `>` token.
        greater_than,
        /// `lhs <= rhs`. The `main_token` field is the `<=` token.
        less_or_equal,
        /// `lhs >= rhs`. The `main_token` field is the `>=` token.
        greater_or_equal,
        /// `lhs = rhs`. The `main_token` field is the `=` token.
        bind,
        /// `!expr`. The `main_token` field is the `!` token.
        bool_not,
        /// `-expr`. The `main_token` field is the `-` token.
        negation,
        /// `(expr)`.
        ///
        /// The `data` field is a `.node_and_token`:
        ///   1. a `Node.Index` to the sub-expression
        ///   2. a `TokenIndex` to the `)` token.
        ///
        /// The `main_token` field is the `(` token.
        grouped_expression,
        /// The `data` field is unused.
        number_literal,
        /// The `data` field is unused.
        string_literal,
        /// The `data` field is unused.
        unreachable_literal,
        /// The `data` field is unused.
        ///
        /// Most identifiers will not have explicit AST nodes, however for
        /// expressions which could be one of many different kinds of AST nodes,
        /// there will be an identifier AST node for it.
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
        /// `a(b, c, d)`.
        ///
        /// The `data` field is a `.node_and_extra`:
        ///   1. a `Node.Index` to the function expression.
        ///   2. a `ExtraIndex` to a `SubRange` that stores a `Node.Index` for
        ///      each argument.
        ///
        /// The `main_token` field is the `(` token.
        call,
    };

    /// some nodes have lhs and rhs data attached to them.
    pub const Data = union {
        node: Index,
        token: TokenIndex,
        node_and_node: struct { Index, Index },
        node_and_token: struct { Index, TokenIndex },
        node_and_extra: struct { Index, ExtraIndex },
        opt_node_and_opt_node: struct { OptionalIndex, OptionalIndex },
        opt_node_and_node: struct { OptionalIndex, Index },
        extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
        extra_range: SubRange,
    };

    pub const FnProto = struct {
        params_start: ExtraIndex,
        params_end: ExtraIndex,
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

    pub const Tag = enum {
        expected_return_type,
        expected_comma_after_arg,
        expected_token,
        expected_expression,
        expected_semi_or_lbrace,
        expected_type_expr,
        expected_comma_after_param,
        expected_fn,
        expected_newline,
    };
};

pub fn fnProto(tree: Ast, node: Node.Index) full.FnProto {
    assert(tree.nodeTag(node) == .fn_proto);
    const extra_index, const return_type = tree.nodeData(node).extra_and_opt_node;
    const extra = tree.extraData(extra_index, Node.FnProto);
    const params = tree.extraDataSlice(.{ .start = extra.params_start, .end = extra.params_end }, Node.Index);
    return tree.fullFnProtoComponents(.{
        .proto_node = node,
        .fn_token = tree.nodeMainToken(node),
        .return_type = return_type,
        .params = params,
        .align_expr = extra.align_expr,
        .addrspace_expr = extra.addrspace_expr,
        .section_expr = extra.section_expr,
        .callconv_expr = extra.callconv_expr,
    });
}

pub fn fullFnProto(tree: Ast, buffer: *[1]Ast.Node.Index, node: Node.Index) ?full.FnProto {
    return switch (tree.nodeTag(node)) {
        .fn_proto => tree.fnProto(node),
        .fn_decl => tree.fullFnProto(buffer, tree.nodeData(node).node_and_node[0]),
        else => null,
    };
}

fn fullFnProtoComponents(tree: Ast, info: full.FnProto.Components) full.FnProto {
    var result: full.FnProto = .{
        .ast = info,
        .name_token = null,
        .lparen = undefined,
    };
    // zig https://codeberg.org/ziglang/zig/src/commit/9c79c784acff94a76fe931a422ef6fecbbb3066b/lib/std/zig/Ast.zig#L2082
    // if we ever want to add prefix keyword to a function
    // var i = info.fn_token;
    // while (i > 0) {
    //     i -= 1;
    //     switch (tree.tokenTag(i)) {
    //         .keyword_extern,
    //         .keyword_export,
    //         => result.extern_export_inline_token = i,
    //         .keyword_pub => result.visib_token = i,
    //         .string_literal => result.lib_name = i,
    //         else => break,
    //     }
    // }
    const after_fn_token = info.fn_token + 1;
    if (tree.tokenTag(after_fn_token) == .identifier) {
        result.name_token = after_fn_token;
        result.lparen = after_fn_token + 1;
    } else {
        result.lparen = after_fn_token;
    }
    assert(tree.tokenTag(result.lparen) == .l_paren);

    return result;
}

/// Fully assembled AST node information.
/// fetch extra_data when needed
const full = struct {
    pub const FnProto = struct {
        name_token: ?TokenIndex,
        lparen: TokenIndex,
        ast: Components,

        pub const Components = struct {
            proto_node: Node.Index,
            fn_token: TokenIndex,
            return_type: Node.OptionalIndex,
            params: []const Node.Index,
        };

        pub const Param = struct {
            name_token: ?TokenIndex,
            type_expr: ?Node.Index,
        };
    };
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
