//! Prints the AST as an indented tree.
//! Walks the AST using the visitor pattern, mirroring `AstGen`.

const AstPrinter = @This();
const Ast = @import("./ast.zig");
const std = @import("std");

const Node = Ast.Node;

tree: *const Ast,
/// current nesting depth, used to indent child nodes
indent: usize = 0,

pub fn print(tree: *const Ast) void {
    var printer = AstPrinter{ .tree = tree };
    printer.visit(.root);
}

fn visit(self: *AstPrinter, node: Node.Index) void {
    const tree = self.tree;
    const tags = tree.nodes.items(.tag);
    const datas = tree.nodes.items(.data);
    const main_tokens = tree.nodes.items(.main_token);
    const token_tags = tree.tokens.items(.tag);

    const i = @intFromEnum(node);
    const tag = tags[i];

    for (0..self.indent) |_| std.debug.print("  ", .{});
    std.debug.print("{s} (main_token {d}: {s})\n", .{
        @tagName(tag),
        main_tokens[i],
        @tagName(token_tags[main_tokens[i]]),
    });

    self.indent += 1;
    defer self.indent -= 1;

    switch (tag) {
        // List of children stored in `extra_data`.
        .root, .block => {
            for (self.extraDataSlice(datas[i].extra_range)) |child| {
                self.visit(child);
            }
        },
        // node_and_node: fn_proto + body block.
        .fn_decl => {
            const proto, const body = datas[i].node_and_node;
            self.visit(proto);
            self.visit(body);
        },
        // extra_and_opt_node: a SubRange of params + optional return type.
        .fn_proto => {
            const extra, const ret = datas[i].extra_and_opt_node;
            const base = @intFromEnum(extra);
            const params: Node.SubRange = .{
                .start = @enumFromInt(tree.extra_data[base]),
                .end = @enumFromInt(tree.extra_data[base + 1]),
            };
            for (self.extraDataSlice(params)) |param| {
                self.visit(param);
            }
            if (ret.unwrap()) |ret_node| self.visit(ret_node);
        },
        // node_and_node: lhs + rhs.
        .add, .sub, .mul, .div, .equal_equal, .bang_equal, .less_than, .greater_than, .less_or_equal, .greater_or_equal, .mod => {
            const lhs, const rhs = datas[i].node_and_node;
            self.visit(lhs);
            self.visit(rhs);
        },
        // opt_node_and_node: optional assignment target + initializer.
        .bind => {
            const target, const initializer = datas[i].opt_node_and_node;
            if (target.unwrap()) |target_node| self.visit(target_node);
            self.visit(initializer);
        },
        // node_and_token: inner expression + the `)` token (not a node).
        .grouped_expression => {
            const expr, _ = datas[i].node_and_token;
            self.visit(expr);
        },
        // node: single operand.
        .bool_not, .negation => self.visit(datas[i].node),
        // Leaf nodes / not produced by the parser yet.
        .number_literal, .string_literal, .unreachable_literal, .identifier, .global_exp => {},
    }
}

/// Interpret a `SubRange` into `extra_data` as a slice of node indices.
fn extraDataSlice(self: *AstPrinter, range: Node.SubRange) []const Node.Index {
    return @ptrCast(self.tree.extra_data[@intFromEnum(range.start)..@intFromEnum(range.end)]);
}
