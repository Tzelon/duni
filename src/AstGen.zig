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

    var top_scope: Scope.Top = .{};
    var instrs: ArrayList(Dir.Inst.Index) = .empty;
    defer instrs.deinit(gpa);

    var main_gd: GenDir = .{
        .decl_node_index = .root,
        .decl_line = 0,
        .cursor = .{ .tip = &top_scope.base },
        .astgen = &astgen,
        .instructions = &instrs,
        .instructions_top = 0,
    };

    for (tree.rootDecls()) |statement| {
        _ = try expr(&main_gd, statement);
    }

    const body = main_gd.instructionsSlice();
    const main_body_start: u32 = @intCast(astgen.extra.items.len);
    const main_body_len: u32 = @intCast(body.len);
    try astgen.extra.ensureUnusedCapacity(gpa, main_body_len);
    for (body) |idx| {
        astgen.extra.appendAssumeCapacity(@intFromEnum(idx));
    }

    try astgen.extra.shrinkToLen(gpa);
    try astgen.string_bytes.shrinkToLen(gpa);

    return .{
        .instructions = astgen.instructions.toOwnedSlice(),
        .extra = astgen.extra.toOwnedSliceAssert(),
        .string_bytes = astgen.string_bytes.toOwnedSliceAssert(),
        .main_body_start = main_body_start,
        .main_body_len = main_body_len,
    };
}

fn expr(gd: *GenDir, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = gd.astgen.tree;

    switch (tree.nodeTag(node)) {
        .number_literal => return numberLiteral(gd, node, node, .positive),
        .string_literal => return stringLiteral(gd, node),

        .identifier => return identifier(gd, node),

        .form => return formExpr(gd, node),
        else => {
            unreachable;
        },
    }
}

const Sign = enum { negative, positive };

fn numberLiteral(gd: *GenDir, node: Ast.Node.Index, source_node: Ast.Node.Index, sign: Sign) InnerError!Dir.Inst.Ref {
    const astgen = gd.astgen;
    const tree = astgen.tree;
    const num_token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(num_token);

    const result: Dir.Inst.Ref = switch (std.zig.parseNumberLiteral(bytes)) {
        .int => |num| switch (num) {
            0 => if (sign == .positive) try gd.addInt(num) else {
                // TODO(tzelon): report through AstGen error reporting once it
                // exists; log.warn because the test runner fails on log.err.
                std.log.warn("0 cannot be negative", .{});
                return error.AnalysisFail;
            },

            else => try gd.addInt(num),
        },
        .big_int => |base| big: {
            var big_int = try std.math.big.int.Managed.init(astgen.gpa);
            defer big_int.deinit();
            const prefix_offset: usize = if (base == .decimal) 0 else 2;
            big_int.setString(@intFromEnum(base), bytes[prefix_offset..]) catch |err| switch (err) {
                error.InvalidCharacter => unreachable, // caught in `parseNumberLiteral`
                error.InvalidBase => unreachable, // we only pass 16, 8, 2, see above
                error.OutOfMemory => |e| return e,
            };

            const limbs = big_int.limbs[0..big_int.len()];
            assert(big_int.isPositive());
            break :big try gd.addIntBig(limbs);
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
            return try gd.addFloat(smaller_float);
        },
        .failure => {
            std.log.warn("failed to parse literal number", .{});
            return error.AnalysisFail;
        },
    };

    if (sign == .positive) {
        return result;
    } else {
        return try gd.addUnNode(.negate, result, source_node);
    }
}

fn stringLiteral(gd: *GenDir, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = gd.astgen.tree;
    const str_lit_token = tree.nodeMainToken(node);
    const str = try gd.astgen.strLitAsString(str_lit_token);
    return gd.add(.{
        .tag = .str,
        .data = .{ .str = .{
            .start = str.index,
            .len = str.len,
        } },
    });
}

fn formExpr(gd: *GenDir, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = gd.astgen.tree;

    const op = tree.formOp(node);
    const args = tree.formArgs(node);

    switch (op) {
        .star => return simpleBinOp(gd, node, args, .mul),
        .plus => return simpleBinOp(gd, node, args, .add),
        .minus => switch (args.len) {
            1 => return negation(gd, node, args),
            2 => return simpleBinOp(gd, node, args, .sub),
            else => unreachable,
        },
        .slash => return simpleBinOp(gd, node, args, .div),
        .equal => return bind(gd, node, args),
        .block => return blockExpr(gd, node, args),
        else => unreachable,
    }
}

fn negation(gd: *GenDir, node: Ast.Node.Index, args: []const Node.Index) InnerError!Dir.Inst.Ref {
    const tree = gd.astgen.tree;

    const operand_node = args[0];

    // Check for float literal as the sub-expression because we want to preserve
    // its negativity rather than having it go through comptime subtraction.
    if (tree.nodeTag(operand_node) == .number_literal) {
        return numberLiteral(gd, operand_node, node, .negative);
    }

    const operand = try expr(gd, operand_node);
    return gd.addUnNode(.negate, operand, node);
}

fn simpleBinOp(gd: *GenDir, node: Ast.Node.Index, args: []const Node.Index, op_inst_tag: Dir.Inst.Tag) InnerError!Dir.Inst.Ref {
    const lhs = try expr(gd, args[0]);
    const rhs = try expr(gd, args[1]);
    return gd.addPlNode(op_inst_tag, node, Dir.Inst.Bin{ .lhs = lhs, .rhs = rhs });
}

fn bind(gd: *GenDir, node: Ast.Node.Index, args: []const Node.Index) InnerError!Dir.Inst.Ref {
    const astgen = gd.astgen;
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
    const rhs = try expr(gd, rhs_node);

    const name_token = tree.nodeMainToken(lhs_node);
    const name = try astgen.identAsString(name_token);

    const local_val = try astgen.scope_arena.allocator().create(Scope.LocalVal);
    local_val.* = .{
        .parent = gd.cursor.tip,
        .name = name,
        .id_cat = .@"local variable",
        .inst = rhs,
        .token_src = name_token,
    };

    gd.cursor.tip = &local_val.base;

    return rhs;
}

fn blockExpr(gd: *GenDir, node: Ast.Node.Index, args: []const Node.Index) InnerError!Dir.Inst.Ref {
    const astgen = gd.astgen;

    // Since this block is unlabeled, its control flow is effectively linear and we
    // can *almost* get away with inlining the block here. However, we actually need
    // to preserve the .block for Sema, to properly pop the error return trace.

    const block_tag: Dir.Inst.Tag = .block;
    const block_inst = try gd.makeBlockInst(block_tag, node);
    try gd.instructions.append(astgen.gpa, block_inst);

    var block_scope = gd.makeSubBlock();
    defer block_scope.unstack();

    for (args) |statement| {
        _ = try expr(&block_scope, statement);
    }

    try block_scope.setBlockBody(block_inst);

    return block_inst.toRef();
}

fn identifier(gd: *GenDir, ident: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = gd.astgen.tree;

    const ident_token = tree.nodeMainToken(ident);
    const ident_name_raw = tree.tokenSlice(ident_token);

    if (primitive_instrs.get(ident_name_raw)) |dir_const_ref| {
        return dir_const_ref;
    }

    return localVarRef(gd, ident, ident_token);
}

fn localVarRef(gd: *GenDir, ident: Ast.Node.Index, ident_token: Ast.TokenIndex) InnerError!Dir.Inst.Ref {
    _ = ident;

    const astgen = gd.astgen;
    const name_str_index = try astgen.identAsString(ident_token);
    find_scope: switch (gd.cursor.tip.unwrap()) {
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

/// This is a temporary structure; references to it are valid only
/// while constructing a `Dir`.
const GenDir = struct {
    /// The containing decl AST node.
    decl_node_index: Ast.Node.Index,
    /// The containing decl line index, absolute.
    decl_line: u32,
    cursor: Scope.Cursor,
    /// All `GenDir` scopes for the same DIR share this.
    astgen: *AstGen,
    /// Keeps track of the list of instructions in this scope. Possibly shared.
    /// Indexes to instructions in `astgen`.
    instructions: *ArrayList(Dir.Inst.Index),
    /// A sub-block may share its instructions ArrayList with containing GenDir,
    /// if use is strictly nested. This saves prior size of list for unstacking.
    instructions_top: usize,

    const unstacked_top = std.math.maxInt(usize);

    /// Call unstack before adding any new instructions to containing GenDir.
    fn unstack(self: *GenDir) void {
        if (self.instructions_top != unstacked_top) {
            self.instructions.items.len = self.instructions_top;
            self.instructions_top = unstacked_top;
        }
    }

    fn isEmpty(self: *const GenDir) bool {
        return (self.instructions_top == unstacked_top) or
            (self.instructions.items.len == self.instructions_top);
    }

    fn instructionsSlice(self: *const GenDir) []Dir.Inst.Index {
        return if (self.instructions_top == unstacked_top)
            &[0]Dir.Inst.Index{}
        else
            self.instructions.items[self.instructions_top..];
    }

    /// Note that this returns a `Dir.Inst.Index` not a ref.
    /// Does *not* append the block instruction to the scope.
    /// Leaves the `payload_index` field undefined.
    fn makeBlockInst(gd: *GenDir, tag: Dir.Inst.Tag, node: Ast.Node.Index) !Dir.Inst.Index {
        const new_index: Dir.Inst.Index = @enumFromInt(gd.astgen.instructions.len);
        const gpa = gd.astgen.gpa;
        try gd.astgen.instructions.append(gpa, .{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gd.nodeIndexToRelative(node),
                .payload_index = undefined,
            } },
        });
        return new_index;
    }

    fn makeSubBlock(gd: *GenDir) GenDir {
        return .{
            .decl_node_index = gd.decl_node_index,
            .decl_line = gd.decl_line,
            .cursor = .{ .tip = gd.cursor.tip },
            .astgen = gd.astgen,
            .instructions = gd.instructions,
            .instructions_top = gd.instructions.items.len,
        };
    }

    /// Assumes nothing stacked on `gd`. Unstacks `gd`.
    fn setBlockBody(gd: *GenDir, inst: Dir.Inst.Index) !void {
        const astgen = gd.astgen;
        const gpa = astgen.gpa;
        const body = gd.instructionsSlice();

        try astgen.extra.ensureUnusedCapacity(
            gpa,
            @typeInfo(Dir.Inst.Block).@"struct".fields.len + body.len,
        );
        const dir_datas = astgen.instructions.items(.data);
        dir_datas[@intFromEnum(inst)].pl_node.payload_index = astgen.addExtraAssumeCapacity(
            Dir.Inst.Block{ .body_len = @intCast(body.len) },
        );

        for (body) |instruction| {
            astgen.extra.appendAssumeCapacity(@intFromEnum(instruction));
        }
        gd.unstack();
    }

    fn nodeIndexToRelative(gd: GenDir, node_index: Ast.Node.Index) Ast.Node.Offset {
        return gd.decl_node_index.toOffset(node_index);
    }

    fn tokenIndexToRelative(gd: GenDir, token: Ast.TokenIndex) Ast.TokenOffset {
        return .init(gd.srcToken(), token);
    }

    fn srcToken(gd: GenDir) Ast.TokenIndex {
        return gd.astgen.tree.firstToken(gd.decl_node_index);
    }

    fn add(gd: *GenDir, inst: Dir.Inst) !Dir.Inst.Ref {
        return (try gd.addAsIndex(inst)).toRef();
    }

    fn addAsIndex(gd: *GenDir, inst: Dir.Inst) !Dir.Inst.Index {
        const gpa = gd.astgen.gpa;
        try gd.instructions.ensureUnusedCapacity(gpa, 1);
        try gd.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const new_index: Dir.Inst.Index = @enumFromInt(gd.astgen.instructions.len);
        gd.astgen.instructions.appendAssumeCapacity(inst);
        gd.instructions.appendAssumeCapacity(new_index);
        return new_index;
    }

    fn addInt(gd: *GenDir, integer: u64) !Dir.Inst.Ref {
        return gd.add(.{
            .tag = .int,
            .data = .{ .int = integer },
        });
    }

    fn addIntBig(gd: *GenDir, limbs: []const std.math.big.Limb) !Dir.Inst.Ref {
        const astgen = gd.astgen;
        const gpa = astgen.gpa;
        try gd.instructions.ensureUnusedCapacity(gpa, 1);
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
        gd.instructions.appendAssumeCapacity(new_index);
        astgen.string_bytes.appendSliceAssumeCapacity(mem.sliceAsBytes(limbs));
        return new_index.toRef();
    }

    fn addFloat(gd: *GenDir, number: f64) !Dir.Inst.Ref {
        return gd.add(.{
            .tag = .float,
            .data = .{ .float = number },
        });
    }

    fn addUnNode(
        gd: *GenDir,
        tag: Dir.Inst.Tag,
        operand: Dir.Inst.Ref,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
    ) !Dir.Inst.Ref {
        assert(operand != .none);
        return gd.add(.{
            .tag = tag,
            .data = .{ .un_node = .{
                .operand = operand,
                .src_node = gd.nodeIndexToRelative(src_node),
            } },
        });
    }

    fn addPlNode(
        gd: *GenDir,
        tag: Dir.Inst.Tag,
        /// Absolute node index. This function does the conversion to offset from Decl.
        src_node: Ast.Node.Index,
        extra: anytype,
    ) !Dir.Inst.Ref {
        const gpa = gd.astgen.gpa;
        try gd.instructions.ensureUnusedCapacity(gpa, 1);
        try gd.astgen.instructions.ensureUnusedCapacity(gpa, 1);

        const payload_index = try gd.astgen.addExtra(extra);
        const new_index: Dir.Inst.Index = @enumFromInt(gd.astgen.instructions.len);
        gd.astgen.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .pl_node = .{
                .src_node = gd.nodeIndexToRelative(src_node),
                .payload_index = payload_index,
            } },
        });
        gd.instructions.appendAssumeCapacity(new_index);
        return new_index.toRef();
    }

    fn addStrTok(
        gd: *GenDir,
        tag: Dir.Inst.Tag,
        str_index: Dir.NullTerminatedString,
        /// Absolute token index. This function does the conversion to Decl offset.
        abs_tok_index: Ast.TokenIndex,
    ) !Dir.Inst.Ref {
        return gd.add(.{
            .tag = tag,
            .data = .{ .str_tok = .{
                .start = str_index,
                .src_tok = gd.tokenIndexToRelative(abs_tok_index),
            } },
        });
    }
};

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

test "rebind rhs sees the previous binding" {
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

test "block" {
    try expect("{ 1 }",
        \\%0 = block(%1) node_offset:1:1 to :1:6
        \\%1 = int(1)
        \\
    );

    try expect(
        \\{
        \\  1 
        \\}
    ,
        \\%0 = block(%1) node_offset:1:1 to :1:2
        \\%1 = int(1)
        \\
    );
}
