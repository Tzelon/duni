//! Abstract Syntax Tree for Duni source code.
//! The root node is at `nodes[0]` and contains the list of sub-nodes.

// The engine that drives the parser to build the AST.

const Ast = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;

const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;

const Parse = @import("Parse.zig");

pub const Node = @import("./Ast/Node.zig");

/// Reference to externally-owned data.
source: [:0]const u8,

// Accumulating tokens from the scanner.
tokens: TokenList.Slice,

/// The root AST node is assumed to be index 0. Since there can be no
/// references to the root node, this means 0 is available to indicate null.
// output
nodes: NodeList.Slice,
extra_data: []u32,
errors: []const Error,

// ByteOffset start position of the token in the source.
pub const ByteOffset = u32;

/// Index into `tokens`.
pub const TokenIndex = u32;
pub const TokenList = std.MultiArrayList(struct {
    tag: Token.Tag,
    start: ByteOffset,
});

pub const NodeList = std.MultiArrayList(Node);

/// A relative token index.
pub const TokenOffset = enum(i32) {
    zero = 0,
    _,

    pub fn init(base: TokenIndex, destination: TokenIndex) TokenOffset {
        const base_i64: i64 = base;
        const destination_i64: i64 = destination;
        return @enumFromInt(destination_i64 - base_i64);
    }

    pub fn toOptional(to: TokenOffset) OptionalTokenOffset {
        const result: OptionalTokenOffset = @enumFromInt(@intFromEnum(to));
        assert(result != .none);
        return result;
    }

    pub fn toAbsolute(offset: TokenOffset, base: TokenIndex) TokenIndex {
        return @intCast(@as(i64, base) + @intFromEnum(offset));
    }
};

/// A relative token index, or null.
pub const OptionalTokenOffset = enum(i32) {
    none = std.math.maxInt(i32),
    _,

    pub fn unwrap(oto: OptionalTokenOffset) ?TokenOffset {
        return if (oto == .none) null else @enumFromInt(@intFromEnum(oto));
    }
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

    // load all tokens
    while (true) {
        const token = scanner.next();
        try tokens.append(gpa, .{
            .tag = token.tag,
            .start = @intCast(token.loc.start),
        });
        if (token.tag == .eof) break;
    }

    // Ast is the owner of all memory

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

pub fn blockExpressions(tree: *const Ast, node: Node.Index) []const Node.Index {
    assert(tree.nodeTag(node) == .block);
    return tree.extraDataSlice(tree.nodeData(node).extra_range, Node.Index);
}

pub fn callArgs(tree: *const Ast, node: Node.Index) []const Node.Index {
    assert(tree.nodeTag(node) == .call);
    const args_index = tree.nodeData(node).node_and_extra[1];
    return tree.extraDataSlice(tree.extraData(args_index, Node.SubRange), Node.Index);
}

/// The prototype's parameter type expression nodes. A parameter's name is
/// the token before its type's first token.
pub fn fnProtoParams(tree: *const Ast, node: Node.Index) []const Node.Index {
    assert(tree.nodeTag(node) == .fn_proto);
    const params_index = tree.nodeData(node).extra_and_opt_node[0];
    return tree.extraDataSlice(tree.extraData(params_index, Node.SubRange), Node.Index);
}

pub fn fnProtoReturnType(tree: *const Ast, node: Node.Index) Node.OptionalIndex {
    assert(tree.nodeTag(node) == .fn_proto);
    return tree.nodeData(node).extra_and_opt_node[1];
}

// Helpers extra data

///  return extra_data from a SubRange
pub fn extraDataSlice(tree: Ast, range: Node.SubRange, comptime T: type) []const T {
    return @ptrCast(tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}

// return node extra_data
pub fn extraData(tree: Ast, index: Node.ExtraIndex, comptime T: type) T {
    const info = @typeInfo(T).@"struct";
    var result: T = undefined;
    inline for (info.fields, 0..) |field, i| {
        @field(result, field.name) = switch (field.type) {
            Node.Index,
            Node.ExtraIndex,
            => @enumFromInt(tree.extra_data[@intFromEnum(index) + i]),
            TokenIndex => tree.extra_data[@intFromEnum(index) + i],
            else => @compileError("unexpected field type: " ++ @typeName(field.type)),
        };
    }
    return result;
}

pub fn rootDecls(tree: Ast) []const Node.Index {
    return tree.extraDataSlice(tree.nodeData(.root).extra_range, Node.Index);
}

// Helpers tokens - yes there is the same helpers in Parse.zig

/// return the lexeme of a token
pub fn tokenSlice(tree: Ast, token_index: TokenIndex) []const u8 {
    const token_tag = tree.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var scanner: Scanner = .{
        .buffer = tree.source,
        .index = tree.tokenStart(token_index),
        .line = 0,
    };
    const token = scanner.next();
    assert(token.tag == token_tag);
    return tree.source[token.loc.start..token.loc.end];
}

pub fn tokenStart(tree: *const Ast, token_index: TokenIndex) ByteOffset {
    return tree.tokens.items(.start)[token_index];
}

pub fn tokenTag(tree: *const Ast, token_index: TokenIndex) Token.Tag {
    return tree.tokens.items(.tag)[token_index];
}

pub fn tokensOnSameLine(tree: Ast, token1: TokenIndex, token2: TokenIndex) bool {
    const source = tree.source[tree.tokenStart(token1)..tree.tokenStart(token2)];
    return mem.findScalar(u8, source, '\n') == null;
}

fn dump(tree: *const Ast) !void {
    const Print = @import("Ast/Print.zig");
    var buffer: [4096]u8 = undefined;
    const locked = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    const w = &locked.file_writer.interface;
    try Print.print(tree, w);
    try w.flush();
}

pub fn deinit(tree: *Ast, gpa: Allocator) void {
    tree.tokens.deinit(gpa);
    tree.nodes.deinit(gpa);
    gpa.free(tree.extra_data);
    gpa.free(tree.errors);
    tree.* = undefined;
}

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
        expected_callee,
    };
};

pub const Span = struct {
    start: u32,
    end: u32,
    main: u32,
};

pub fn nodeToSpan(tree: *const Ast, node: Ast.Node.Index) Span {
    return tokensToSpan(
        tree,
        tree.firstToken(node),
        tree.lastToken(node),
        tree.nodeMainToken(node),
    );
}

pub fn tokenToSpan(tree: *const Ast, token: Ast.TokenIndex) Span {
    return tokensToSpan(tree, token, token, token);
}

pub fn tokensToSpan(tree: *const Ast, start: Ast.TokenIndex, end: Ast.TokenIndex, main: Ast.TokenIndex) Span {
    var start_tok = start;
    var end_tok = end;

    if (tree.tokensOnSameLine(start, end)) {
        // do nothing
    } else if (tree.tokensOnSameLine(start, main)) {
        end_tok = main;
    } else if (tree.tokensOnSameLine(main, end)) {
        start_tok = main;
    } else {
        start_tok = main;
        end_tok = main;
    }
    const start_off = tree.tokenStart(start_tok);
    const end_off = tree.tokenStart(end_tok) + @as(u32, @intCast(tree.tokenSlice(end_tok).len));
    return Span{ .start = start_off, .end = end_off, .main = tree.tokenStart(main) };
}

pub fn firstToken(tree: *const Ast, node: Node.Index) TokenIndex {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .root => return 0,

        .string_literal,
        .number_literal,
        .identifier,
        .negation,
        .block,
        .fn_decl,
        .grouped_expression,
        => return tree.nodeMainToken(n),

        .fn_proto => {
            // The `extern` keyword, when present, is the token before `fn`.
            const main_token = tree.nodeMainToken(n);
            if (main_token > 0 and tree.tokenTag(main_token - 1) == .keyword_extern) return main_token - 1;
            return main_token;
        },

        .add, .sub, .mul, .div, .assign => n = tree.nodeData(n).node_and_node[0],

        .call => n = tree.nodeData(n).node_and_extra[0],
    };
}

pub fn lastToken(tree: *const Ast, node: Node.Index) TokenIndex {
    var n = node;
    std.debug.print(">>>>>> nodetag: {}\n", .{tree.nodeTag(n)});
    while (true) switch (tree.nodeTag(n)) {
        .root => return @intCast(tree.tokens.len - 1),
        .identifier, .string_literal, .number_literal => return tree.nodeMainToken(n),

        .negation => n = tree.nodeData(n).node,

        .add,
        .sub,
        .mul,
        .div,
        .assign,
        .fn_decl,
        => n = tree.nodeData(n).node_and_node[1],

        .grouped_expression => return tree.nodeData(n).node_and_token[1],

        .block => {
            const extra_index = tree.nodeData(n).extra;
            const block = tree.extraData(extra_index, Node.Block);
            return block.rbrace;
        },

        .call => {
            _, const extra_index = tree.nodeData(n).node_and_extra;
            const call = tree.extraData(extra_index, Node.Call);
            return call.rparen;
        },

        .fn_proto => {
            if (tree.fnProtoReturnType(n).unwrap()) |return_type| {
                n = return_type;
                continue;
            }
            // No return type (recoverable error): the params `)` ends the proto.
            const extra_index = tree.nodeData(n).extra_and_opt_node[0];
            return tree.extraData(extra_index, Node.FnProto).rparen;
        },
    };
}

/// A node shape for structural test assertions: the expected tag plus the
/// expected shapes of the node's children in source order.
const Expected = struct {
    tag: Node.Tag,
    children: []const Expected = &.{},
};

fn expectAst(source: [:0]const u8, expected: Expected) !void {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expect(tree.errors.len == 0);
    for (tree.rootDecls()) |statement| {
        try expectNode(&tree, statement, expected);
    }
}

fn expectNode(tree: *const Ast, node: Node.Index, expected: Expected) !void {
    try std.testing.expectEqual(expected.tag, tree.nodeTag(node));

    switch (tree.nodeTag(node)) {
        .root => unreachable, // the root is never a child

        .identifier, .number_literal, .string_literal => {
            try std.testing.expectEqual(0, expected.children.len);
        },

        .negation => {
            try std.testing.expectEqual(1, expected.children.len);
            try expectNode(tree, tree.nodeData(node).node, expected.children[0]);
        },

        .grouped_expression => {
            try std.testing.expectEqual(1, expected.children.len);
            try expectNode(tree, tree.nodeData(node).node_and_token[0], expected.children[0]);
        },

        .add, .sub, .mul, .div, .assign, .fn_decl => {
            try std.testing.expectEqual(2, expected.children.len);
            const lhs, const rhs = tree.nodeData(node).node_and_node;
            try expectNode(tree, lhs, expected.children[0]);
            try expectNode(tree, rhs, expected.children[1]);
        },

        .block => {
            const statements = tree.blockExpressions(node);
            try std.testing.expectEqual(expected.children.len, statements.len);
            for (statements, expected.children) |statement, expected_child| {
                try expectNode(tree, statement, expected_child);
            }
        },

        // Children are the callee followed by the args.
        .call => {
            const callee = tree.nodeData(node).node_and_extra[0];
            const args = tree.callArgs(node);
            try std.testing.expectEqual(expected.children.len, 1 + args.len);
            try expectNode(tree, callee, expected.children[0]);
            for (args, expected.children[1..]) |arg, expected_child| {
                try expectNode(tree, arg, expected_child);
            }
        },

        // Children are the param types followed by the return type, if any.
        .fn_proto => {
            const params = tree.fnProtoParams(node);
            const return_type = tree.fnProtoReturnType(node).unwrap();
            const expected_len = params.len + @intFromBool(return_type != null);
            try std.testing.expectEqual(expected.children.len, expected_len);
            for (params, expected.children[0..params.len]) |param, expected_child| {
                try expectNode(tree, param, expected_child);
            }
            if (return_type) |return_type_node| {
                try expectNode(tree, return_type_node, expected.children[params.len]);
            }
        },
    }
}

test "parser" {
    try expectAst("42", .{ .tag = .number_literal });
}

/// Parses a single root declaration and asserts the token index `lastToken`
/// returns for it. Asserting the index (not the lexeme) is the point: the
/// failure modes return the wrong instance of the same lexeme.
fn expectLastToken(source: [:0]const u8, expected: TokenIndex) !void {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expect(tree.errors.len == 0);

    const decls = tree.rootDecls();
    try std.testing.expectEqual(1, decls.len);
    try std.testing.expectEqual(expected, tree.lastToken(decls[0]));
}

test "lastToken" {
    // try expectLastToken("42", 0); // leaf
    // try expectLastToken("1 + 2", 2); // rhs walk
    // try expectLastToken("-x", 1); // operand walk
    // try expectLastToken("(1 + 2)", 4); // stored `)`
    // try expectLastToken("{}", 1); // empty block
    // try expectLastToken("(1 + 2) * (2 / (4 - 1))", 14); // empty block
    // // `{`(0) `1`(1) newline(2) `}`(3) — the `\n` after `{` is swallowed by
    // // automatic newline insertion, the one after `1` is not.
    // try expectLastToken("{\n1\n}", 3); // scan past the newline
    // try expectLastToken("f()", 2); // empty call
    // try expectLastToken("f(1,)", 4); // scan past the trailing comma
    // try expectLastToken("f((1+1))", 7); // the call's `)`, not the grouping's (4)
    // try expectLastToken("fn f() t {}", 6); // body walk
    try expectLastToken("extern fn f() t", 5); // return type walk
}

test "left associative & precedence" {
    try expectAst("1 + 1 * 2", .{ .tag = .add, .children = &.{
        .{ .tag = .number_literal },
        .{ .tag = .mul, .children = &.{
            .{ .tag = .number_literal },
            .{ .tag = .number_literal },
        } },
    } });

    try expectAst("1 + (1 - 2) * 2", .{ .tag = .add, .children = &.{
        .{ .tag = .number_literal },
        .{ .tag = .mul, .children = &.{
            .{ .tag = .sub, .children = &.{
                .{ .tag = .number_literal },
                .{ .tag = .number_literal },
            } },
            .{ .tag = .number_literal },
        } },
    } });

    try expectAst("1 - 2 - 3", .{ .tag = .sub, .children = &.{
        .{ .tag = .sub, .children = &.{
            .{ .tag = .number_literal },
            .{ .tag = .number_literal },
        } },
        .{ .tag = .number_literal },
    } });
}

test "block" {
    try expectAst("{}", .{ .tag = .block });

    try expectAst(
        \\{
        \\  1
        \\  2
        \\}
    ,
        .{ .tag = .block, .children = &.{
            .{ .tag = .number_literal },
            .{ .tag = .number_literal },
        } },
    );
}

test "fn declaration" {
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, "fn add(x number, y number) number {}");
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    const decls = tree.rootDecls();
    try std.testing.expectEqual(1, decls.len);
    try expectNode(&tree, decls[0], .{
        .tag = .fn_decl,
        .children = &.{
            .{
                .tag = .fn_proto,
                .children = &.{
                    .{ .tag = .identifier }, // x's type
                    .{ .tag = .identifier }, // y's type
                    .{ .tag = .identifier }, // return type
                },
            },
            .{ .tag = .block },
        },
    });

    // Names are not nodes: the fn name follows the `fn` token, a param
    // name precedes its type expression.
    const proto = tree.nodeData(decls[0]).node_and_node[0];
    try std.testing.expectEqualStrings("add", tree.tokenSlice(tree.nodeMainToken(proto) + 1));
    const first_param = tree.fnProtoParams(proto)[0];
    try std.testing.expectEqualStrings("x", tree.tokenSlice(tree.firstToken(first_param) - 1));
}

test "extern fn declaration" {
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, "extern fn print(x number) number");
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    const decls = tree.rootDecls();
    try std.testing.expectEqual(1, decls.len);
    try expectNode(&tree, decls[0], .{
        .tag = .fn_proto,
        .children = &.{
            .{ .tag = .identifier }, // x's type
            .{ .tag = .identifier }, // return type
        },
    });

    // The extern-ness of a bare proto lives in the token before its `fn`.
    try std.testing.expectEqual(Token.Tag.keyword_extern, tree.tokenTag(tree.firstToken(decls[0])));
}

test "fn call" {
    try expectAst("add(1, 2)", .{ .tag = .call, .children = &.{
        .{ .tag = .identifier },
        .{ .tag = .number_literal },
        .{ .tag = .number_literal },
    } });
}

test "dump" {
    var tree = try Ast.parse(std.testing.allocator, "1 - 2 - 3");
    defer tree.deinit(std.testing.allocator);
    try tree.dump();
}
