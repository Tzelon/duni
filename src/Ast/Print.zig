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
        .root => for (self.tree.rootDecls()) |statement| {
            try self.visit(statement);
        },

        // leaf nodes: no children to visit.
        .identifier, .number_literal, .string_literal => {},

        .negation => try self.visit(datas[i].node),

        .add, .sub, .mul, .div, .assign, .fn_decl => {
            const lhs, const rhs = datas[i].node_and_node;
            try self.visit(lhs);
            try self.visit(rhs);
        },

        .block => for (tree.blockStatements(node)) |statement| {
            try self.visit(statement);
        },

        .call => {
            try self.visit(datas[i].node_and_extra[0]);
            for (tree.callArgs(node)) |arg| {
                try self.visit(arg);
            }
        },

        .fn_proto => {
            for (tree.fnProtoParams(node)) |param| {
                try self.visit(param);
            }
            if (tree.fnProtoReturnType(node).unwrap()) |return_type| {
                try self.visit(return_type);
            }
        },
    }
}
