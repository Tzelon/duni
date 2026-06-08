//! generates Middle Intermediate Representation

const AstGen = @This();

const Ast = @import("Ast.zig");
const Node = Ast.Node;

const Dir = @import("Dir.zig");

const std = @import("std");
const log = std.log.scoped(.astgen);
const assert = std.debug.assert;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;

const InnerError = error{ OutOfMemory, AnalysisFail };

gpa: Allocator,
tree: *const Ast,
instructions: std.MultiArrayList(Dir.Inst) = .{},

pub fn generate(gpa: Allocator, tree: Ast) !Dir {
    var astgen = AstGen{
        .tree = &tree,
        .gpa = gpa,
    };

    defer astgen.deinit(gpa);

    // We expect at least as many DIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    const root_data = tree.nodes.items(.data)[0];
    _ = try astgen.expr(root_data.node);

    return .{
        .instructions = astgen.instructions.toOwnedSlice(),
    };
}

fn expr(astgen: *AstGen, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    switch (tree.nodeTag(node)) {
        .number_literal => return numberLiteral(astgen, node, .positive),
        else => {
            unreachable;
        },
    }
}

const Sign = enum { negative, positive };

fn numberLiteral(astgen: *AstGen, node: Ast.Node.Index, sign: Sign) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;
    const num_token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(num_token);

    const result: Dir.Inst.Ref = switch (std.zig.parseNumberLiteral(bytes)) {
        .int => |num| switch (num) {
            0 => if (sign == .positive) try astgen.addInt(num) else {
                std.log.err("0 cannot be negative", .{});
                return error.AnalysisFail;
            },

            else => try astgen.addInt(num),
        },
        .big_int => {
            // TODO(tzelon): support big int
            std.log.err("implement big_int", .{});
            return error.AnalysisFail;
        },
        .float => {
            // TODO(tzelon): support big int
            std.log.err("implement big_int", .{});
            return error.AnalysisFail;
        },
        .failure => {
            std.log.err("failed to parse literal number", .{});
            return error.AnalysisFail;
        },
    };

    return result;
}

fn addInt(astgen: *AstGen, integer: u64) !Dir.Inst.Ref {
    return astgen.add(.{
        .tag = .int,
        .data = .{ .int = integer },
    });
}

fn add(astgen: *AstGen, inst: Dir.Inst) !Dir.Inst.Ref {
    return (try astgen.addAsIndex(inst)).toRef();
}

fn addAsIndex(astgen: *AstGen, inst: Dir.Inst) !Dir.Inst.Index {
    const gpa = astgen.gpa;
    try astgen.instructions.ensureUnusedCapacity(gpa, 1);

    const new_index: Dir.Inst.Index = @enumFromInt(astgen.instructions.len);
    astgen.instructions.appendAssumeCapacity(inst);
    return new_index;
}

fn deinit(astgen: *AstGen, gpa: Allocator) void {
    astgen.instructions.deinit(gpa);
}

fn expectDir(source: [:0]const u8, expected: []const Dir.Inst) !void {
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    var dir = try AstGen.generate(gpa, tree);
    defer dir.deinit(gpa);

    const tags = dir.instructions.items(.tag);
    const datas = dir.instructions.items(.data);
    try std.testing.expectEqual(expected.len, dir.instructions.len);

    for (expected, tags, datas) |exp, tag, data| {
        try std.testing.expectEqual(exp.tag, tag);
        switch (exp.tag) {
            .int => try std.testing.expectEqual(exp.data.int, data.int),
        }
    }
}

test "int literal" {
    try expectDir("42", &.{
        .{ .tag = .int, .data = .{ .int = 42 } },
    });
}
