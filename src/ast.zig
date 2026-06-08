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
