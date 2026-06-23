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
extra: ArrayList(u32) = .empty,

pub fn generate(gpa: Allocator, tree: Ast) !Dir {
    var astgen = AstGen{
        .tree = &tree,
        .gpa = gpa,
    };

    defer astgen.deinit(gpa);

    // We expect at least as many DIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    try astgen.extra.ensureTotalCapacity(gpa, tree.nodes.len);

    const root_data = tree.nodes.items(.data)[0];
    _ = try astgen.expr(root_data.node);

    // TODO: this is super hacky for now, when we do not have proper body
    // Append the body slice: every emitted instruction is part of the main body.
    const body_len: u32 = @intCast(astgen.instructions.len);
    const main_body_start: u32 = @intCast(astgen.extra.items.len);
    try astgen.extra.ensureUnusedCapacity(gpa, body_len);
    for (0..body_len) |i| {
        astgen.extra.appendAssumeCapacity(@intCast(i));
    }

    try astgen.extra.shrinkToLen(gpa);

    return .{
        .instructions = astgen.instructions.toOwnedSlice(),
        .extra = astgen.extra.toOwnedSliceAssert(),
        .main_body_start = main_body_start,
        .main_body_len = body_len,
    };
}

fn expr(astgen: *AstGen, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    switch (tree.nodeTag(node)) {
        .number_literal => return numberLiteral(astgen, node, .positive),
        .form => return formExpr(astgen, node),
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
                std.debug.print("error: 0 cannot be negative\n", .{});
                return error.AnalysisFail;
            },

            else => try astgen.addInt(num),
        },
        .big_int => {
            std.debug.print("error: integer literal exceeds 64-bit range\n", .{});
            return error.AnalysisFail;
        },
        .float => {
            // Float literals are designed-in but not lowered yet; only division
            // produces a float for now.
            std.debug.print("error: float literals not yet supported\n", .{});
            return error.AnalysisFail;
        },
        .failure => {
            std.debug.print("error: failed to parse literal number\n", .{});
            return error.AnalysisFail;
        },
    };

    return result;
}

fn formExpr(astgen: *AstGen, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    const op = tree.formOp(node);
    const args = tree.formArgs(node);

    switch (op) {
        .star => return astgen.simpleBinOp(node, args, .mul),
        .plus => return astgen.simpleBinOp(node, args, .add),
        .minus => switch (args.len) {
            1 => return astgen.negation(node, args),
            2 => return astgen.simpleBinOp(node, args, .sub),
            else => unreachable,
        },
        .slash => return astgen.simpleBinOp(node, args, .div),
        else => unreachable,
    }
}

fn negation(
    astgen: *AstGen,
    node: Ast.Node.Index,
    args: []const Node.Index,
) InnerError!Dir.Inst.Ref {
    // const tree = astgen.tree;

    // Check for float literal as the sub-expression because we want to preserve
    // its negativity rather than having it go through comptime subtraction.
    // const operand_node = tree.nodeData(node).node;
    // if (tree.nodeTag(operand_node) == .number_literal) {
    //     return numberLiteral(gz, ri, operand_node, node, .negative);
    // }

    const operand = try astgen.expr(args[0]);
    const result = try astgen.addUnNode(.negate, operand, node);
    return result;
}

fn simpleBinOp(astgen: *AstGen, node: Ast.Node.Index, args: []const Node.Index, op_inst_tag: Dir.Inst.Tag) InnerError!Dir.Inst.Ref {
    const lhs = try astgen.expr(args[0]);
    const rhs = try astgen.expr(args[1]);

    const result = try astgen.addPlNode(op_inst_tag, node, Dir.Inst.Bin{ .lhs = lhs, .rhs = rhs });

    return result;
}

fn addPlNode(
    astgen: *AstGen,
    tag: Dir.Inst.Tag,
    /// Absolute node index. This function does the conversion to offset from Decl.
    src_node: Ast.Node.Index,
    extra: anytype,
) !Dir.Inst.Ref {
    const gpa = astgen.gpa;
    try astgen.instructions.ensureUnusedCapacity(gpa, 1);

    const payload_index = try astgen.addExtra(extra);
    const new_index: Dir.Inst.Index = @enumFromInt(astgen.instructions.len);
    astgen.instructions.appendAssumeCapacity(.{
        .tag = tag,
        .data = .{ .pl_node = .{
            .src_node = astgen.nodeIndexToRelative(src_node),
            .payload_index = payload_index,
        } },
    });
    // astgen.instructions.appendAssumeCapacity(new_index);
    return new_index.toRef();
}

fn addUnNode(
    astgen: *AstGen,
    tag: Dir.Inst.Tag,
    operand: Dir.Inst.Ref,
    /// Absolute node index. This function does the conversion to offset from Decl.
    src_node: Ast.Node.Index,
) !Dir.Inst.Ref {
    assert(operand != .none);
    return astgen.add(.{
        .tag = tag,
        .data = .{ .un_node = .{
            .operand = operand,
            .src_node = astgen.nodeIndexToRelative(src_node),
        } },
    });
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

fn addExtra(astgen: *AstGen, extra: anytype) Allocator.Error!u32 {
    const field_count = std.meta.fieldNames(@TypeOf(extra)).len;
    try astgen.extra.ensureUnusedCapacity(astgen.gpa, field_count);
    return addExtraAssumeCapacity(astgen, extra);
}

fn addExtraAssumeCapacity(astgen: *AstGen, extra: anytype) u32 {
    const field_count = std.meta.fieldNames(@TypeOf(extra)).len;
    const extra_index: u32 = @intCast(astgen.extra.items.len);
    astgen.extra.items.len += field_count;
    setExtra(astgen, extra_index, extra);
    return extra_index;
}

fn setExtra(astgen: *AstGen, index: usize, extra: anytype) void {
    const info = @typeInfo(@TypeOf(extra)).@"struct";
    var i = index;
    inline for (info.fields) |field| {
        astgen.extra.items[i] = switch (field.type) {
            u32 => @field(extra, field.name),

            Dir.Inst.Ref,
            Dir.Inst.Index,
            // Dir.NullTerminatedString,
            // Ast.TokenIndex is missing because it is a u32.
            Ast.Node.Index,
            => @intFromEnum(@field(extra, field.name)),

            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @bitCast(@intFromEnum(@field(extra, field.name))),

            i32,
            => @bitCast(@field(extra, field.name)),

            else => @compileError("bad field type"),
        };
        i += 1;
    }
}

fn reserveExtra(astgen: *AstGen, size: usize) Allocator.Error!u32 {
    const extra_index: u32 = @intCast(astgen.extra.items.len);
    try astgen.extra.resize(astgen.gpa, extra_index + size);
    return extra_index;
}

fn nodeIndexToRelative(astgen: *AstGen, node_index: Ast.Node.Index) Ast.Node.Offset {
    // TODO: should be return gz.decl_node_index.toOffset(node_index);
    // relevant when we want to cache location per decl
    _ = astgen;
    return Ast.Node.Index.root.toOffset(node_index);
}

fn deinit(astgen: *AstGen, gpa: Allocator) void {
    astgen.instructions.deinit(gpa);
    astgen.extra.deinit(gpa);
}

fn expect(source: [:0]const u8, expected: [:0]const u8) !void {
    const Print = @import("print_dir.zig");
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    try std.testing.expect(tree.errors.len == 0);

    var dir = try AstGen.generate(gpa, tree);
    defer dir.deinit(gpa);

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try Print.print(&dir, &tree, &w);

    try std.testing.expectEqualStrings(expected, w.buffer[0..w.end]);
}

test "int literal" {
    try expect("42",
        \\%0 = int(42)
        \\
    );
}

test "simple binary op" {
    try expect("1 + 2",
        \\%0 = int(1)
        \\%1 = int(2)
        \\%2 = add(%0, %1) node_offset:1:1 to :1:6
        \\
    );

    try expect("1 + 2 * 5 / 10",
        \\%0 = int(1)
        \\%1 = int(2)
        \\%2 = int(5)
        \\%3 = mul(%1, %2) node_offset:1:5 to :1:10
        \\%4 = int(10)
        \\%5 = div(%3, %4) node_offset:1:5 to :1:15
        \\%6 = add(%0, %5) node_offset:1:1 to :1:15
        \\
    );

    try expect("1 * (2 - 5) / 10",
        \\%0 = int(1)
        \\%1 = int(2)
        \\%2 = int(5)
        \\%3 = sub(%1, %2) node_offset:1:6 to :1:11
        \\%4 = mul(%0, %3) node_offset:1:1 to :1:11
        \\%5 = int(10)
        \\%6 = div(%4, %5) node_offset:1:1 to :1:17
        \\
    );
}
