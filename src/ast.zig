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

const string = @import("string.zig");
const NullTerminatedString = string.NullTerminatedString;

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

pub fn formOp(tree: *const Ast, node: Node.Index) NullTerminatedString {
    assert(tree.nodeTag(node) == .form);
    return tree.nodeData(node).form.op;
}

pub fn formArgs(tree: *const Ast, node: Node.Index) []const Node.Index {
    assert(tree.nodeTag(node) == .form);
    const extra = tree.extraData(tree.nodeData(node).form.args, Node.SubRange);
    return tree.extraDataSlice(extra, Node.Index);
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

        .string_literal, .number_literal, .identifier => return tree.nodeMainToken(n),

        .form => {
            const args = tree.formArgs(n);

            // Unary form: operator (main_token) sits to the left of its single arg.
            if (args.len == 1) return tree.nodeMainToken(n);

            const op = tree.formOp(n);
            switch (op) {
                .block => return tree.nodeMainToken(n),
                else => {
                    n = args[0];
                },
            }
        },
    };
}

pub fn lastToken(tree: *const Ast, node: Node.Index) TokenIndex {
    var n = node;
    while (true) switch (tree.nodeTag(n)) {
        .root => return @intCast(tree.tokens.len - 1),
        .identifier, .string_literal, .number_literal => return tree.nodeMainToken(n),

        .form => {
            const args = tree.formArgs(n);
            const op = tree.formOp(n);

            switch (op) {
                .block => {
                    var tok = tree.nodeMainToken(node);
                    while (tree.tokenTag(tok) != .r_brace) : (tok += 1) {}
                    return tok;
                },
                else => {
                    n = args[args.len - 1];
                },
            }
        },
    };
}

const Expected = union(enum) {
    number_literal,
    form: struct {
        op: NullTerminatedString,
        args: []const Expected,
    },
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
    switch (expected) {
        .number_literal => try std.testing.expectEqual(
            Node.Tag.number_literal,
            tree.nodeTag(node),
        ),
        .form => |f| {
            try std.testing.expectEqual(Node.Tag.form, tree.nodeTag(node));
            try std.testing.expectEqual(f.op, tree.formOp(node));
            const args = tree.formArgs(node);
            try std.testing.expectEqual(f.args.len, args.len);
            for (f.args, args) |exp_child, actual_child| {
                try expectNode(tree, actual_child, exp_child);
            }
        },
    }
}

fn expectParse(source: [:0]const u8, expected: []const Node.Tag) !void {
    var tree = try Ast.parse(std.testing.allocator, source);
    defer tree.deinit(std.testing.allocator);
    try std.testing.expect(tree.errors.len == 0);
    try std.testing.expectEqualSlices(Node.Tag, expected, tree.nodes.items(.tag));
}

test "parser" {
    try expectAst("42", .number_literal);
}

test "left associative & precedence" {
    // zig fmt: off
    try expectAst("1 + 1 * 2", .{ 
        .form = .{ 
            .op = .plus,
            .args = &.{ 
                .number_literal, .{ 
                    .form = .{ 
                        .op = .star,
                        .args = &.{ .number_literal, .number_literal } 
                    } 
                }
            }
        } 
    });
    // zig fmt: on

    // zig fmt: off
    try expectAst("1 + (1 - 2) * 2", .{
        .form = .{
            .op = .plus,
            .args = &.{
                .number_literal,
                .{
                    .form = .{
                        .op = .star,
                        .args = &.{
                            .{
                                .form = .{
                                    .op = .minus,
                                    .args = &.{ .number_literal, .number_literal },
                                },
                            },
                            .number_literal

                        }
                    },
                },
            },
        },
    });
    // zig fmt: on

    // zig fmt: off
      try expectAst("1 - 2 - 3", .{
          .form = .{
              .op = .minus,
              .args = &.{
                  .{
                      .form = .{
                          .op = .minus,
                          .args = &.{ .number_literal, .number_literal },
                      },
                  },
                  .number_literal,
              },
          },
      });
      // zig fmt: on
}

test "block" {
    try expectAst("{}", .{ .form = .{ .op = .block, .args = &.{} } });

    // zig fmt: off
    try expectAst(
        \\{
        \\  1
        \\  2
        \\}
        ,
        .{ .form = .{ .op = .block, .args = &.{ .number_literal, .number_literal } } },
    );
    // zig fmt: on
}

test "dump" {
    var tree = try Ast.parse(std.testing.allocator, "1 - 2 - 3");
    defer tree.deinit(std.testing.allocator);
    try tree.dump();
}
