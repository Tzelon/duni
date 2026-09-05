//! Abstract Syntax Tree for Duni source code.
//! The root node is at `nodes[0]` and contains the list of sub-nodes.

// The engine that drives the parser to build the AST.

const Ast = @This();

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

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
    const block = tree.extraData(tree.nodeData(node).extra, Node.Block);
    return tree.extraDataSlice(.{ .start = block.expressions_start, .end = block.expressions_end }, Node.Index);
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

    // special case for `.newline`.
    if (token_tag == .newline) return "\n";

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
    /// A child note of a parent error, appended immediately after the parent.
    is_note: bool = false,
    /// True if `token` points to the token before the token causing an issue.
    token_is_prev: bool = false,
    token: TokenIndex,
    extra: union { none: void, expected_tag: Token.Tag } = .{ .none = {} },

    pub const Tag = enum {
        expected_callee,
        expected_expression,
        expected_return_type,
        expected_token,
        expected_type_expr,
        unexpected_rbrace,
        extern_fn_body,
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

pub fn renderError(tree: Ast, parse_error: Error, w: *Writer) Writer.Error!void {
    switch (parse_error.tag) {
        .expected_callee => {
            return w.print("expected a function name, found '{s}'", .{
                tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev)).symbol(),
            });
        },
        .expected_expression => {
            return w.print("expected expression, found '{s}'", .{
                tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev)).symbol(),
            });
        },
        .expected_return_type => {
            return w.print("expected return type expression, found '{s}'", .{
                tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev)).symbol(),
            });
        },
        .expected_type_expr => {
            return w.print("expected type expression, found '{s}'", .{
                tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev)).symbol(),
            });
        },
        .expected_token => {
            const found_tag = tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev));
            const expected_symbol = parse_error.extra.expected_tag.symbol();
            const token_slice = tree.tokenSlice(parse_error.token + @intFromBool(parse_error.token_is_prev));
            switch (found_tag) {
                .invalid => return w.print("found invalid bytes '{s}'", .{token_slice}),
                else => return w.print("expected '{s}', found '{s}'", .{
                    expected_symbol, found_tag.symbol(),
                }),
            }
        },
        .unexpected_rbrace => {
            return w.print("unexpected '{s}' no matching '{{'", .{
                tree.tokenTag(parse_error.token + @intFromBool(parse_error.token_is_prev)).symbol(),
            });
        },
        .extern_fn_body => {
            return w.writeAll("extern functions have no body");
        },
    }
}

/// Returns an extra offset for column and byte offset of errors that
/// should point after the token in the error message.
pub fn errorOffset(tree: Ast, parse_error: Error) u32 {
    return if (parse_error.token_is_prev) @intCast(tree.tokenSlice(parse_error.token).len) else 0;
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
            const extra_index, const return_type = tree.nodeData(n).extra_and_opt_node;
            if (return_type.unwrap()) |return_type_node| {
                n = return_type_node;
                continue;
            }
            // No return type (recoverable error): the params `)` ends the proto.
            return tree.extraData(extra_index, Node.FnProto).rparen;
        },
    };
}

/// Fully assembled AST node information.
pub const full = struct {
    pub const FnProto = struct {
        extern_token: ?TokenIndex,
        lib_name: ?TokenIndex,
        name_token: TokenIndex,
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

        pub fn firstToken(fn_proto: FnProto) TokenIndex {
            return fn_proto.extern_token orelse
                fn_proto.ast.fn_token;
        }

        /// iterate over the params and get the name token
        pub const Iterator = struct {
            tree: *const Ast,
            fn_proto: *const FnProto,
            /// next unconsumed index into fn_proto.ast.params
            param_i: usize,

            pub fn next(it: *Iterator) ?Param {
                const tree = it.tree;
                var name_token: ?TokenIndex = null;
                if (it.param_i >= it.fn_proto.ast.params.len) {
                    return null;
                }
                const param_type = it.fn_proto.ast.params[it.param_i];
                it.param_i += 1;

                while (true) {
                    var tok_i = tree.firstToken(param_type) - 1;
                    while (true) : (tok_i -= 1) switch (tree.tokenTag(tok_i)) {
                        .identifier => name_token = tok_i,
                        else => break,
                    };
                    return Param{
                        .name_token = name_token,
                        .type_expr = param_type,
                    };
                }
            }
        };

        pub fn iterate(fn_proto: *const FnProto, tree: *const Ast) Iterator {
            return .{
                .tree = tree,
                .fn_proto = fn_proto,
                .param_i = 0,
            };
        }
    };

    pub const Call = struct {
        ast: Components,

        pub const Components = struct {
            lparen: TokenIndex,
            fn_expr: Node.Index,
            params: []const Node.Index,
        };
    };
};

pub fn fullFnProto(tree: Ast, node: Ast.Node.Index) full.FnProto {
    assert(tree.nodeTag(node) == .fn_proto);

    const extra_index, const return_type = tree.nodeData(node).extra_and_opt_node;
    const extra = tree.extraData(extra_index, Node.FnProto);
    const params = tree.extraDataSlice(.{ .start = extra.params_start, .end = extra.params_end }, Node.Index);
    const fn_token = tree.nodeMainToken(node);

    var result = full.FnProto{
        .name_token = undefined,
        .lparen = undefined,
        .extern_token = null,
        .lib_name = null,
        .ast = .{
            .params = params,
            .return_type = return_type,
            .fn_token = fn_token,
            .proto_node = node,
        },
    };

    // go backward and get the extern token if exists
    var i = fn_token;
    while (i > 0) {
        i -= 1;
        switch (tree.tokenTag(i)) {
            .keyword_extern => result.extern_token = i,
            .string_literal => result.lib_name = i,
            else => break,
        }
    }

    // go forward and get the function name and l_paren
    const after_fn_token = fn_token + 1;
    if (tree.tokenTag(after_fn_token) == .identifier) {
        result.name_token = after_fn_token;
        result.lparen = after_fn_token + 1;
    } else {
        std.log.err("missing function name", .{});
        // TODO(tzelon): comptime time fail here. in Duni all functions must have names
    }

    assert(tree.tokenTag(result.lparen) == .l_paren);

    return result;
}

pub fn fullCall(tree: Ast, node: Node.Index) full.Call {
    const fn_expr, const extra_index = tree.nodeData(node).node_and_extra;
    const params = tree.extraDataSlice(tree.extraData(extra_index, Node.SubRange), Node.Index);
    return .{ .ast = .{
        .lparen = tree.nodeMainToken(node),
        .fn_expr = fn_expr,
        .params = params,
    } };
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
            const callee, const extra_index = tree.nodeData(node).node_and_extra;
            const call = tree.extraData(extra_index, Node.Call);
            const args = tree.extraDataSlice(.{ .start = call.args_start, .end = call.args_end }, Node.Index);
            try std.testing.expectEqual(expected.children.len, 1 + args.len);
            try expectNode(tree, callee, expected.children[0]);
            for (args, expected.children[1..]) |arg, expected_child| {
                try expectNode(tree, arg, expected_child);
            }
        },

        // Children are the param types followed by the return type, if any.
        .fn_proto => {
            const extra_index, const return_type_opt = tree.nodeData(node).extra_and_opt_node;
            const proto = tree.extraData(extra_index, Node.FnProto);
            const params = tree.extraDataSlice(.{ .start = proto.params_start, .end = proto.params_end }, Node.Index);
            const return_type = return_type_opt.unwrap();
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
            .{ .tag = .grouped_expression, .children = &.{
                .{ .tag = .sub, .children = &.{
                    .{ .tag = .number_literal },
                    .{ .tag = .number_literal },
                } },
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
    const proto_extra = tree.extraData(tree.nodeData(proto).extra_and_opt_node[0], Node.FnProto);
    const params = tree.extraDataSlice(.{ .start = proto_extra.params_start, .end = proto_extra.params_end }, Node.Index);
    try std.testing.expectEqualStrings("x", tree.tokenSlice(tree.firstToken(params[0]) - 1));
}

test "extern fn declaration" {
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, "extern fn print(x number) void");
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
