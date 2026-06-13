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
    if (tag == .root) {
        try self.w.print("root\n", .{});
    } else {
        try self.w.print("{s} (token {d} .{s} \"{s}\")\n", .{
            @tagName(tag),
            main_token,
            @tagName(token_tags[main_token]),
            tree.tokenSlice(main_token),
        });
    }

    self.indent += 1;
    defer self.indent -= 1;

    switch (tag) {
        // node: single child expression.
        .root => try self.visit(datas[i].node),
        .number_literal => {},
        .form => {
            const form = datas[i].form;
            const sr_pos = @intFromEnum(form.args);
            const start = tree.extra_data[sr_pos];
            const end = tree.extra_data[sr_pos + 1];
            for (start..end) |j| {
                const child: Node.Index = @enumFromInt(tree.extra_data[j]);
                try self.visit(child);
            }
        },
    }
}
