//! generates Middle Intermediate Representation
//! using the visitor pattern

const AstGen = @This();
const Ast = @import("./ast.zig");
const std = @import("std");

const Allocator = std.mem.Allocator;
const Node = Ast.Node;

gpa: Allocator,
tree: *const Ast,

pub fn generate(gpa: Allocator, tree: Ast) !void {
    var astgen = AstGen{ .tree = &tree, .gpa = gpa };

    try astgen.traverseTree(0);
}

fn traverseTree(self: *AstGen, node: Ast.Node.Index) Allocator.Error!void {
    const tree_tags = self.tree.nodes.items(.tag);
    const tree_data = self.tree.nodes.items(.data);
    const main_token = self.tree.nodes.items(.main_token);

    switch (tree_tags[node]) {
        .root => {
            try self.traverseTree(tree_data[node].lhs);
        },
        .global_exp => {
            try self.traverseTree(tree_data[node].lhs);
        },
        .add => {
            try self.traverseTree(tree_data[node].lhs);
            std.debug.print("add {any} \n", .{main_token[node]});
            try self.traverseTree(tree_data[node].rhs);
        },
        .number_literal => {
            std.debug.print("number_literal {any} \n", .{main_token[node]});
        },
        else => unreachable,
    }
}
