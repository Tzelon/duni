//! generates Middle Intermediate Representation

const AstGen = @This();

const Ast = @import("Ast.zig");
const Node = Ast.Node;

const Dir = @import("Dir.zig");

const Scope = @import("AstGen/Scope.zig");

const std = @import("std");
const log = std.log.scoped(.astgen);
const assert = std.debug.assert;
const mem = std.mem;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const StringIndexAdapter = std.hash_map.StringIndexAdapter;
const StringIndexContext = std.hash_map.StringIndexContext;

const InnerError = error{ OutOfMemory, AnalysisFail };

gpa: Allocator,
tree: *const Ast,
instructions: std.MultiArrayList(Dir.Inst) = .{},
extra: ArrayList(u32) = .empty,

string_bytes: ArrayList(u8) = .empty,

/// Owns all scopes
scope_arena: std.heap.ArenaAllocator,

/// dedupe table of strings
string_table: std.HashMapUnmanaged(u32, void, StringIndexContext, std.hash_map.default_max_load_percentage) = .empty,

pub fn generate(gpa: Allocator, tree: Ast) !Dir {
    var astgen = AstGen{
        .tree = &tree,
        .gpa = gpa,
        .scope_arena = std.heap.ArenaAllocator.init(gpa),
    };

    defer astgen.deinit(gpa);

    // String table index 0 is reserved for `NullTerminatedString.empty`.
    try astgen.string_bytes.append(gpa, 0);

    // We expect at least as many DIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    try astgen.extra.ensureTotalCapacity(gpa, tree.nodes.len);

    // end-of-chain marker
    var top_scope: Scope.Top = .{};
    // Tip of the scope chain
    var scope_cursor: Scope.Cursor = .{ .tip = &top_scope.base };

    for (tree.rootDecls()) |statement| {
        _ = try astgen.expr(&scope_cursor, statement);
    }

    // TODO: this is super hacky for now, when we do not have proper body
    // Append the body slice: every emitted instruction is part of the main body.
    const body_len: u32 = @intCast(astgen.instructions.len);
    const main_body_start: u32 = @intCast(astgen.extra.items.len);
    try astgen.extra.ensureUnusedCapacity(gpa, body_len);
    for (0..body_len) |i| {
        astgen.extra.appendAssumeCapacity(@intCast(i));
    }

    try astgen.extra.shrinkToLen(gpa);
    try astgen.string_bytes.shrinkToLen(gpa);

    return .{
        .instructions = astgen.instructions.toOwnedSlice(),
        .extra = astgen.extra.toOwnedSliceAssert(),
        .string_bytes = astgen.string_bytes.toOwnedSliceAssert(),
        .main_body_start = main_body_start,
        .main_body_len = body_len,
    };
}

fn expr(astgen: *AstGen, scope_cursor: *Scope.Cursor, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    switch (tree.nodeTag(node)) {
        .number_literal => return numberLiteral(astgen, node, node, .positive),
        .string_literal => return stringLiteral(astgen, node),

        .identifier => return identifier(astgen, scope_cursor, node),

        .form => return formExpr(astgen, scope_cursor, node),
        else => {
            unreachable;
        },
    }
}

const Sign = enum { negative, positive };

fn numberLiteral(astgen: *AstGen, node: Ast.Node.Index, source_node: Ast.Node.Index, sign: Sign) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;
    const num_token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(num_token);

    const result: Dir.Inst.Ref = switch (std.zig.parseNumberLiteral(bytes)) {
        .int => |num| switch (num) {
            0 => if (sign == .positive) try astgen.addInt(num) else {
                // TODO(tzelon): report through AstGen error reporting once it
                // exists; log.warn because the test runner fails on log.err.
                std.log.warn("0 cannot be negative", .{});
                return error.AnalysisFail;
            },

            else => try astgen.addInt(num),
        },
        .big_int => |base| big: {
            const gpa = astgen.gpa;
            var big_int = try std.math.big.int.Managed.init(gpa);
            defer big_int.deinit();
            const prefix_offset: usize = if (base == .decimal) 0 else 2;
            big_int.setString(@intFromEnum(base), bytes[prefix_offset..]) catch |err| switch (err) {
                error.InvalidCharacter => unreachable, // caught in `parseNumberLiteral`
                error.InvalidBase => unreachable, // we only pass 16, 8, 2, see above
                error.OutOfMemory => |e| return e,
            };

            const limbs = big_int.limbs[0..big_int.len()];
            assert(big_int.isPositive());
            break :big try astgen.addIntBig(limbs);
        },
        .float => {
            const unsigned_float_number = std.fmt.parseFloat(f128, bytes) catch |err| switch (err) {
                error.InvalidCharacter => unreachable, // validated by tokenizer
            };
            const float_number = switch (sign) {
                .negative => -unsigned_float_number,
                .positive => unsigned_float_number,
            };
            @setFloatMode(.strict);
            const smaller_float: f64 = @floatCast(float_number);
            const result = try astgen.addFloat(smaller_float);
            return result;
        },
        .failure => {
            std.log.warn("failed to parse literal number", .{});
            return error.AnalysisFail;
        },
    };

    if (sign == .positive) {
        return result;
    } else {
        const negated = try astgen.addUnNode(.negate, result, source_node);
        return negated;
    }
}

fn stringLiteral(
    astgen: *AstGen,
    node: Ast.Node.Index,
) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;
    const str_lit_token = tree.nodeMainToken(node);
    const str = try astgen.strLitAsString(str_lit_token);
    const result = try astgen.add(.{
        .tag = .str,
        .data = .{ .str = .{
            .start = str.index,
            .len = str.len,
        } },
    });
    return result;
}

fn formExpr(astgen: *AstGen, scope_cursor: *Scope.Cursor, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    const op = tree.formOp(node);
    const args = tree.formArgs(node);

    switch (op) {
        .star => return astgen.simpleBinOp(scope_cursor, node, args, .mul),
        .plus => return astgen.simpleBinOp(scope_cursor, node, args, .add),
        .minus => switch (args.len) {
            1 => return astgen.negation(scope_cursor, node, args),
            2 => return astgen.simpleBinOp(scope_cursor, node, args, .sub),
            else => unreachable,
        },
        .slash => return astgen.simpleBinOp(scope_cursor, node, args, .div),
        .equal => return astgen.bind(scope_cursor, node, args),
        else => unreachable,
    }
}

fn negation(
    astgen: *AstGen,
    scope_cursor: *Scope.Cursor,
    node: Ast.Node.Index,
    args: []const Node.Index,
) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    const operand_node = args[0];

    // Check for float literal as the sub-expression because we want to preserve
    // its negativity rather than having it go through comptime subtraction.
    if (tree.nodeTag(operand_node) == .number_literal) {
        return numberLiteral(astgen, operand_node, node, .negative);
    }

    const operand = try astgen.expr(scope_cursor, operand_node);
    const result = try astgen.addUnNode(.negate, operand, node);
    return result;
}

fn simpleBinOp(astgen: *AstGen, scope_cursor: *Scope.Cursor, node: Ast.Node.Index, args: []const Node.Index, op_inst_tag: Dir.Inst.Tag) InnerError!Dir.Inst.Ref {
    const lhs = try astgen.expr(scope_cursor, args[0]);
    const rhs = try astgen.expr(scope_cursor, args[1]);

    const result = try astgen.addPlNode(op_inst_tag, node, Dir.Inst.Bin{ .lhs = lhs, .rhs = rhs });

    return result;
}

fn bind(astgen: *AstGen, scope_cursor: *Scope.Cursor, node: Ast.Node.Index, args: []const Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;
    _ = node;
    const lhs_node = args[0];
    const rhs_node = args[1];

    // The lhs is a pattern; today only a plain identifier is supported.
    if (tree.nodeTag(lhs_node) != .identifier) {
        // TODO(tzelon): AstGen error reporting phase 1.
        std.log.warn("unsupported pattern", .{});
        return error.AnalysisFail;
    }

    // Lower the rhs BEFORE pushing the note: in `x = x + 1`, the rhs `x`
    // must see the old binding.
    const rhs = try astgen.expr(scope_cursor, rhs_node);

    const name_token = tree.nodeMainToken(lhs_node);
    const name = try astgen.identAsString(name_token);

    const local_val = try astgen.scope_arena.allocator().create(Scope.LocalVal);
    local_val.* = .{
        .parent = scope_cursor.tip,
        .name = name,
        .id_cat = .@"local variable",
        .inst = rhs,
        .token_src = name_token,
    };

    scope_cursor.tip = &local_val.base;

    return rhs;
}

fn identifier(
    astgen: *AstGen,
    scope_cursor: *Scope.Cursor,
    ident: Ast.Node.Index,
) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    const ident_token = tree.nodeMainToken(ident);
    const ident_name_raw = tree.tokenSlice(ident_token);

    if (primitive_instrs.get(ident_name_raw)) |dir_const_ref| {
        return dir_const_ref;
    }

    return localVarRef(astgen, scope_cursor, ident, ident_token);
}

fn localVarRef(
    astgen: *AstGen,
    scope_cursor: *Scope.Cursor,
    ident: Ast.Node.Index,
    ident_token: Ast.TokenIndex,
) InnerError!Dir.Inst.Ref {
    _ = ident;

    const name_str_index = try astgen.identAsString(ident_token);
    find_scope: switch (scope_cursor.tip.unwrap()) {
        .local_val => |local_val| {
            if (local_val.name == name_str_index) {
                // rebinding pushes the newest binding nearest the tip, so first match IS the shadowing semantics.
                return local_val.inst;
            }
            continue :find_scope local_val.parent.unwrap();
        },
        .top => break :find_scope,
    }

    // No namespaces yet: the scope chain is the complete set of names,
    // so a miss means the identifier is undeclared.
    // TODO(tzelon): AstGen error reporting phase 1.
    std.log.warn("use of undeclared identifier '{s}'", .{try astgen.identifierTokenString(ident_token)});
    return error.AnalysisFail;
}

fn identAsString(astgen: *AstGen, ident_token: Ast.TokenIndex) !Dir.NullTerminatedString {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index: u32 = @intCast(string_bytes.items.len);
    try astgen.appendIdentStr(ident_token, string_bytes);
    const key: []const u8 = string_bytes.items[str_index..];
    const gop = try astgen.string_table.getOrPutContextAdapted(gpa, key, StringIndexAdapter{
        .bytes = string_bytes,
    }, StringIndexContext{
        .bytes = string_bytes,
    });
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return @enumFromInt(gop.key_ptr.*);
    } else {
        gop.key_ptr.* = str_index;
        try string_bytes.append(gpa, 0);
        return @enumFromInt(str_index);
    }
}

const IndexSlice = struct { index: Dir.NullTerminatedString, len: u32 };

fn strLitAsString(astgen: *AstGen, str_lit_token: Ast.TokenIndex) !IndexSlice {
    const gpa = astgen.gpa;
    const string_bytes = &astgen.string_bytes;
    const str_index: u32 = @intCast(string_bytes.items.len);
    const token_bytes = astgen.tree.tokenSlice(str_lit_token);
    try astgen.parseStrLit(str_lit_token, string_bytes, token_bytes, 0);
    const key: []const u8 = string_bytes.items[str_index..];
    if (std.mem.findScalar(u8, key, 0)) |_| return .{
        .index = @enumFromInt(str_index),
        .len = @intCast(key.len),
    };
    const gop = try astgen.string_table.getOrPutContextAdapted(gpa, key, StringIndexAdapter{
        .bytes = string_bytes,
    }, StringIndexContext{
        .bytes = string_bytes,
    });
    if (gop.found_existing) {
        string_bytes.shrinkRetainingCapacity(str_index);
        return .{
            .index = @enumFromInt(gop.key_ptr.*),
            .len = @intCast(key.len),
        };
    } else {
        gop.key_ptr.* = str_index;
        // Still need a null byte because we are using the same table
        // to lookup null terminated strings, so if we get a match, it has to
        // be null terminated for that to work.
        try string_bytes.append(gpa, 0);
        return .{
            .index = @enumFromInt(str_index),
            .len = @intCast(key.len),
        };
    }
}

/// Given an identifier token, obtain the string for it and append the string to `buf`.
/// See also `identifierTokenString` and `parseStrLit`.
fn appendIdentStr(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    buf: *ArrayList(u8),
) InnerError!void {
    const tree = astgen.tree;
    assert(tree.tokenTag(token) == .identifier);
    const ident_name = tree.tokenSlice(token);
    return buf.appendSlice(astgen.gpa, ident_name);
}

/// Given an identifier token, obtain the string for it.
/// returns a reference to the source code bytes directly.
/// See also `appendIdentStr` and `parseStrLit`.
fn identifierTokenString(astgen: *AstGen, token: Ast.TokenIndex) InnerError![]const u8 {
    const tree = astgen.tree;
    assert(tree.tokenTag(token) == .identifier);
    const ident_name = tree.tokenSlice(token);
    return ident_name;
}

/// Appends the result to `buf`.
fn parseStrLit(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    buf: *ArrayList(u8),
    bytes: []const u8,
    offset: u32,
) InnerError!void {
    _ = token;
    const raw_string = bytes[offset..];
    const result = r: {
        var aw: std.Io.Writer.Allocating = .fromArrayList(astgen.gpa, buf);
        defer buf.* = aw.toArrayList();
        break :r std.zig.string_literal.parseWrite(&aw.writer, raw_string) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
        };
    };
    switch (result) {
        .success => return,
        .failure => |err| return std.log.warn("{f}", .{err.fmt(raw_string)}), //astgen.failWithStrLitError(err, token, bytes, offset),
    }
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

fn addIntBig(astgen: *AstGen, limbs: []const std.math.big.Limb) !Dir.Inst.Ref {
    const gpa = astgen.gpa;
    try astgen.instructions.ensureUnusedCapacity(gpa, 1);
    try astgen.string_bytes.ensureUnusedCapacity(gpa, @sizeOf(std.math.big.Limb) * limbs.len);

    const new_index: Dir.Inst.Index = @enumFromInt(astgen.instructions.len);
    astgen.instructions.appendAssumeCapacity(.{
        .tag = .int_big,
        .data = .{ .str = .{
            .start = @enumFromInt(astgen.string_bytes.items.len),
            .len = @intCast(limbs.len),
        } },
    });

    astgen.string_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(limbs));
    return new_index.toRef();
}

fn addFloat(astgen: *AstGen, number: f64) !Dir.Inst.Ref {
    return astgen.add(.{
        .tag = .float,
        .data = .{ .float = number },
    });
}

fn addStrTok(
    astgen: *AstGen,
    tag: Dir.Inst.Tag,
    str_index: Dir.NullTerminatedString,
    /// Absolute token index. This function does the conversion to Decl offset.
    abs_tok_index: Ast.TokenIndex,
) !Dir.Inst.Ref {
    return astgen.add(.{
        .tag = tag,
        .data = .{ .str_tok = .{
            .start = str_index,
            .src_tok = astgen.tokenIndexToRelative(abs_tok_index),
        } },
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

fn tokenIndexToRelative(astgen: AstGen, token: Ast.TokenIndex) Ast.TokenOffset {
    return .init(astgen.srcToken(), token);
}

fn srcToken(astgen: AstGen) Ast.TokenIndex {
    _ = astgen;
    // TODO: first token of the containing decl once decls exist (gz.srcToken in Zig)
    // today the whole module is the decl, and its first token is 0.
    return 0;
}

const primitive_instrs = std.StaticStringMap(Dir.Inst.Ref).initComptime(.{
    // .{ "bool", .bool_type },
    .{ "comptime_float", .comptime_float_type },
    .{ "comptime_int", .comptime_int_type },
    // .{ "false", .bool_false },
    // .{ "null", .null_value },
    // .{ "true", .bool_true },
    // .{ "type", .type_type },
    // .{ "undefined", .undef },
    // .{ "void", .void_type },
    //
    // .{ "f16", .f16_type },
    // .{ "f32", .f32_type },
    .{ "f64", .f64_type },
    // .{ "u32", .u32_type },
    // .{ "i32", .i32_type },
    // .{ "u64", .u64_type },
    // .{ "i64", .i64_type },
});

fn deinit(astgen: *AstGen, gpa: Allocator) void {
    astgen.instructions.deinit(gpa);
    astgen.extra.deinit(gpa);
    astgen.string_bytes.deinit(gpa);
    astgen.string_table.deinit(gpa);
    astgen.scope_arena.deinit();
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
    try Print.print(&dir, &tree, &w, gpa);

    try std.testing.expectEqualStrings(expected, w.buffer[0..w.end]);
}

test "int literal" {
    try expect("42",
        \\%0 = int(42)
        \\
    );
}

test "float literal" {
    try expect("3.14",
        \\%0 = float(3.14)
        \\
    );
}

test "big int literal" {
    try expect("18446744073709551616", // 2^64, one past u64
        \\%0 = int_big(18446744073709551616)
        \\
    );
}

test "string literal" {
    try expect("\"hello world\"",
        \\%0 = str(hello world)
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

test "negation" {
    // int literal: stored positive, sign is a negate instruction
    try expect("-5",
        \\%0 = int(5)
        \\%1 = negate(%0) node_offset:1:1 to :1:3
        \\
    );
    // float literal: sign folds into the constant, no negate
    try expect("-3.14",
        \\%0 = float(-3.14)
        \\
    );
    // non-literal operand: general path. The negate span excludes the closing
    // paren: parens produce no AST node, so `lastToken` stops at the inner `2`.
    // See TODO(tzelon) on Parse.grouping.
    try expect("-(1 + 2)",
        \\%0 = int(1)
        \\%1 = int(2)
        \\%2 = add(%0, %1) node_offset:1:3 to :1:8
        \\%3 = negate(%2) node_offset:1:1 to :1:8
        \\
    );
}

test "negative zero int is rejected" {
    const gpa = std.testing.allocator;
    var tree = try Ast.parse(gpa, "-0");
    defer tree.deinit(gpa);
    try std.testing.expectError(error.AnalysisFail, AstGen.generate(gpa, tree));
}

test "bind expression" {
    try expect("x = 1",
        \\%0 = int(1)
        \\
    );
}

test "bind lookup and rebinding" {
    try expect(
        \\x = 1
        \\x = x + 2
        \\x
    ,
        \\%0 = int(1)
        \\%1 = int(2)
        \\%2 = add(%0, %1) node_offset:2:5 to :2:10
        \\
    );
}

test "rebind rhs sess the previous binding" {
    try expect(
        \\x = 1
        \\x = x + 1
    ,
        \\%0 = int(1)
        \\%1 = int(1)
        \\%2 = add(%0, %1) node_offset:2:5 to :2:10
        \\
    );
}
