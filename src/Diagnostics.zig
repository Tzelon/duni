//! Compile-error collector shared by every stage (Parse, AstGen, Sema).
//! A stage appends structured items with a source location; the CLI renders
//! them against the tree at the end as `<path>:<line>:<col>: error: <msg>`.
//!
//! Locations are either an already-resolved byte offset (stages that hold
//! the tree resolve immediately) or a node (Sema has no tree by design —
//! Dir's stated exception lets compile errors reach back into the AST, so
//! node locations resolve at render time).

const Diagnostics = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

gpa: Allocator,
items: std.ArrayList(Item) = .empty,

pub const Loc = union(enum) {
    /// Byte offset into the source.
    byte: u32,
    /// The node's first token (e.g. a call error points at the callee).
    node_start: Ast.Node.Index,
    /// The node's main token (e.g. a binary-operator error points at the
    /// operator).
    node_main: Ast.Node.Index,
};

pub const Item = struct {
    loc: Loc,
    /// Owned by the Diagnostics' gpa.
    msg: []u8,
};

pub fn addError(d: *Diagnostics, loc: Loc, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    const msg = try std.fmt.allocPrint(d.gpa, fmt, args);
    errdefer d.gpa.free(msg);
    try d.items.append(d.gpa, .{ .loc = loc, .msg = msg });
}

pub fn hasErrors(d: *const Diagnostics) bool {
    return d.items.items.len != 0;
}

/// Convert the parser's recoverable errors into diagnostics. Kept here so
/// `Ast.Error` stays a plain record and the message wording lives with the
/// rest of the diagnostics.
pub fn addParseErrors(d: *Diagnostics, tree: *const Ast) Allocator.Error!void {
    for (tree.errors) |parse_error| {
        const token = parse_error.token - @intFromBool(parse_error.token_is_prev);
        const loc: Loc = .{ .byte = tree.tokenStart(token) };
        switch (parse_error.tag) {
            .expected_expression => try d.addError(loc, "expected expression, found '{s}'", .{tree.tokenTag(token).symbol()}),
            .expected_return_type => try d.addError(loc, "expected return type", .{}),
            .expression_nested_too_deeply => try d.addError(loc, "expression nested too deeply", .{}),
            .expected_token => try d.addError(loc, "expected '{s}', found '{s}'", .{
                parse_error.extra.expected_tag.symbol(),
                tree.tokenTag(token).symbol(),
            }),
            .expected_comma_after_arg => try d.addError(loc, "expected ',' after call argument", .{}),
            .expected_semi_or_lbrace => try d.addError(loc, "expected newline or block", .{}),
            .expected_type_expr => try d.addError(loc, "expected type expression, found '{s}'", .{tree.tokenTag(token).symbol()}),
            .expected_comma_after_param => try d.addError(loc, "expected ',' after parameter", .{}),
            .expected_fn => try d.addError(loc, "expected function declaration", .{}),
            .expected_newline => try d.addError(loc, "expected newline, found '{s}'", .{tree.tokenTag(token).symbol()}),
            .expected_callee => try d.addError(loc, "expected a callable expression", .{}),
        }
    }
}

/// Render every item as `<path>:<line>:<col>: error: <msg>`, one per line.
pub fn render(d: *const Diagnostics, tree: *const Ast, path: []const u8, w: *std.Io.Writer) !void {
    for (d.items.items) |item| {
        const byte: u32 = switch (item.loc) {
            .byte => |byte| byte,
            .node_start => |node| tree.tokenStart(tree.firstToken(node)),
            .node_main => |node| tree.tokenStart(tree.nodeMainToken(node)),
        };
        const line_col = lineCol(tree.source, byte);
        try w.print("{s}:{d}:{d}: error: {s}\n", .{ path, line_col.line, line_col.col, item.msg });
    }
}

fn lineCol(source: []const u8, byte: u32) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var line_start: u32 = 0;
    for (source[0..byte], 0..) |char, i| {
        if (char == '\n') {
            line += 1;
            line_start = @intCast(i + 1);
        }
    }
    return .{ .line = line, .col = byte - line_start + 1 };
}

pub fn deinit(d: *Diagnostics) void {
    for (d.items.items) |item| d.gpa.free(item.msg);
    d.items.deinit(d.gpa);
    d.* = undefined;
}

test "diagnostics render with line and column" {
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, "1 + 2\nx + 3");
    defer tree.deinit(gpa);

    var diags = Diagnostics{ .gpa = gpa };
    defer diags.deinit();

    // Byte 6 is the `x` on line 2, column 1.
    try diags.addError(.{ .byte = 6 }, "something about '{s}'", .{"x"});
    try std.testing.expect(diags.hasErrors());

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try diags.render(&tree, "test.duni", &w);
    try std.testing.expectEqualStrings(
        "test.duni:2:1: error: something about 'x'\n",
        w.buffer[0..w.end],
    );
}
