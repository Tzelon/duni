//! Abstract Syntax Tree for Duni source code.
//! The root node is at `nodes[0]` and contains the list of sub-nodes.

// The engine that drives the parser to build the AST.

const Ast = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;

const Parse = @import("parse.zig");

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

    pub const Tag = enum {
        /// sub_list[lhs...rhs]
        root,
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
        // /// `lhs < rhs`. The `main_token` field is the `<` token.
        // less_than,
        // /// `lhs > rhs`. The `main_token` field is the `>` token.
        // greater_than,
        // /// `lhs <= rhs`. The `main_token` field is the `<=` token.
        // less_or_equal,
        // /// `lhs >= rhs`. The `main_token` field is the `>=` token.
        // greater_or_equal,
        // /// `lhs = rhs`. The `main_token` field is the `=` token.
        // bind,
        // /// `!expr`. The `main_token` field is the `!` token.
        // bool_not,
        // /// `-expr`. The `main_token` field is the `-` token.
        // negation,
        // /// `(expr)`.
        // ///
        // /// The `data` field is a `.node_and_token`:
        // ///   1. a `Node.Index` to the sub-expression
        // ///   2. a `TokenIndex` to the `)` token.
        // ///
        // /// The `main_token` field is the `(` token.
        // grouped_expression,
        /// The `data` field is unused.
        number_literal,
        /// The `data` field is unused.
        string_literal,
        // /// The `data` field is unused.
        // unreachable_literal,
        // /// The `data` field is unused.
        // ///
        // /// Most identifiers will not have explicit AST nodes, however for
        // /// expressions which could be one of many different kinds of AST nodes,
        // /// there will be an identifier AST node for it.
        // identifier,
        // /// `fn (a: b, c: d) return_type`.
        // ///
        // /// The `data` field is a `.extra_and_opt_node`:
        // ///   1. a `Node.ExtraIndex` to `FnProto`.
        // ///   2. a `Node.OptionalIndex` to the return type expression. Can't be
        // ///      `.none` unless a parsing error occured.
        // ///
        // /// The `main_token` field is the `fn` token.
        // ///
        // /// Extern function declarations use this tag.
        // fn_proto,
        // /// Extern function declarations use the fn_proto tags rather than this one.
        // ///
        // /// The `data` field is a `.node_and_node`:
        // ///   1. a `Node.Index` to `fn_proto_*`.
        // ///   2. a `Node.Index` to function body block.
        // ///
        // /// The `main_token` field is the `fn` token.
        // fn_decl,
        // /// `{a b}`.
        // ///
        // /// The `data` field is a `.extra_range` that stores a `Node.Index` for
        // /// each statement.
        // ///
        // /// The `main_token` field is the `{` token.
        // block,
        // /// `a(b, c, d)`.
        // ///
        // /// The `data` field is a `.node_and_extra`:
        // ///   1. a `Node.Index` to the function expression.
        // ///   2. a `ExtraIndex` to a `SubRange` that stores a `Node.Index` for
        // ///      each argument.
        // ///
        // /// The `main_token` field is the `(` token.
        // call,
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
pub const NodeList = std.MultiArrayList(Node);

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

/// Result should be freed with tree.deinit() when there are
/// no more references to any of the tokens or nodes.
pub fn parse(gpa: Allocator, source: [:0]const u8) !Ast {
    var tokens = Ast.TokenList{};
    defer tokens.deinit(gpa);

    // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
    // TODO(tzelon): what is the right number for duni?
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

    // keep the tokens_slice ownership in this scope
    var tokens_slice = tokens.toOwnedSlice();
    errdefer tokens_slice.deinit(gpa);

    var parser: Parse = .{
        .source = source,
        .gpa = gpa,
        .tokens = tokens_slice,
        .errors = .empty,
        .nodes = .empty,
        .extra_data = .empty,
        .scratch = .empty,
        .token_index = 0,
    };

    defer parser.errors.deinit(parser.gpa);
    defer parser.nodes.deinit(parser.gpa);
    defer parser.extra_data.deinit(parser.gpa);
    defer parser.scratch.deinit(parser.gpa);

    // Empirically, Zig source code has a 2:1 ratio of tokens to AST nodes.
    // Make sure at least 1 so we can use appendAssumeCapacity on the root node below.
    // TODO(tzelon): what is the right number for duni?
    const estimated_node_count = (tokens_slice.len + 2) / 2;
    try parser.nodes.ensureTotalCapacity(gpa, estimated_node_count);

    try parser.parseRoot();

    try parser.extra_data.shrinkToLen(gpa);
    try parser.errors.shrinkToLen(gpa);

    return Ast{
        .source = source,
        .tokens = tokens_slice,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = parser.extra_data.toOwnedSliceAssert(),
        .errors = parser.errors.toOwnedSliceAssert(),
    };
}

pub fn rootDecls(tree: Ast) []const Node.Index {
    // Root is always index 0.
    const nodes_data = tree.nodes.items(.data);
    return tree.extra_data[nodes_data[0].lhs..nodes_data[0].rhs];
}

// Helpers nodes

pub fn nodeTag(self: *const Ast, node: Node.Index) Node.Tag {
    return self.nodes.items(.tag)[@intFromEnum(node)];
}

pub fn nodeMainToken(tree: *const Ast, node: Node.Index) TokenIndex {
    return tree.nodes.items(.main_token)[@intFromEnum(node)];
}

pub fn nodeData(tree: *const Ast, node: Node.Index) Node.Data {
    return tree.nodes.items(.data)[@intFromEnum(node)];
}

// Helpers tokens

pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
    const token_tag = tree.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var scanner: Scanner = .{
        .line = 0,
        .buffer = tree.source,
        .index = tree.tokenStart(token_index),
    };
    const token = scanner.next();
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[token_index];
}

pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[token_index];
}

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

fn dump(tree: *Ast) !void {
    const Print = @import("Ast/Print.zig");
    var buffer: [4096]u8 = undefined;
    const locked = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &locked.file_writer.interface;
    try Print.print(tree, w);
    try w.flush();
}

fn expectParse(source: [:0]const u8, expected: []const Node.Tag) !void {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expectEqualSlices(Node.Tag, expected, tree.nodes.items(.tag));
}

test "parser" {
    try expectParse("42", &.{ .root, .number_literal });
}

test "dump" {
    var tree = try Ast.parse(std.testing.allocator, "42_2");
    defer tree.deinit(std.testing.allocator);
    try tree.dump();
}
