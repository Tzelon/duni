//! Prints the AST as an indented tree.
//! Walks the AST using the visitor pattern, mirroring `AstGen`.

const Print = @This();
const std = @import("std");
const Ast = @import("../Ast.zig");

const Node = Ast.Node;

w: *std.Io.Writer,
tree: *const Ast,
/// current nesting depth, used to indent child nodes
indent: usize = 0,

pub fn print(tree: *const Ast, w: *std.Io.Writer) !void {
    var printer = Print{ .w = w, .tree = tree };
    try printer.visit(.root);
}

fn visit(self: *Print, node: Node.Index) !void {
    const tree = self.tree;
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    const i = @intFromEnum(node);
    const tag = tags[i];
    const main_token = main_tokens[i];

    try self.w.splatByteAll(' ', self.indent * 2);
    try self.w.print("{s} (token {d} .{s} \"{s}\")\n", .{
        @tagName(tag),
        main_token,
        @tagName(token_tags[main_token]),
        tokenSlice(tree, main_token),
    });

    self.indent += 1;
    defer self.indent -= 1;

    switch (tag) {
        // node: single child expression.
        .root => try self.visit(datas[i].node),
        .number_literal => {},
        else => std.debug.panic("AstPrint: unhandled tag .{s}", .{@tagName(tag)}),
    }
}

/// Recover the source text for a token by re-scanning from its start offset.
fn tokenSlice(tree: *const Ast, ti: Ast.TokenIndex) []const u8 {
    const Scanner = @import("../scanner.zig").Scanner;
    const start: usize = tree.tokens.items(.start)[ti];
    var scanner = Scanner.init(tree.source);
    scanner.index = start;
    const tok = scanner.next();
    return tree.source[start..tok.loc.end];
}
