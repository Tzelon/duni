//! generates Middle Intermediate Representation
//! using the visitor pattern

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
const StringIndexAdapter = std.hash_map.StringIndexAdapter;
const StringIndexContext = std.hash_map.StringIndexContext;

const InnerError = error{ OutOfMemory, AnalysisFail };

gpa: Allocator,
tree: *const Ast,
instructions: std.MultiArrayList(Dir.Inst) = .{},
/// Used for temporary allocations; freed after AstGen is complete.
/// The resulting DIR code has no references to anything in this arena.
// arena: Allocator,

pub fn generate(gpa: Allocator, tree: Ast) !Dir {
    // var arena = std.heap.ArenaAllocator.init(gpa);
    // defer arena.deinit();

    var astgen = AstGen{
        .tree = &tree,
        // .arena = arena.allocator(),
        .gpa = gpa,
    };
    defer astgen.deinit(gpa);

    // We expect at least as many DIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    // var top_scope: Scope.Top = .{};
    //
    // var gz_instructions: std.ArrayList(Dir.Inst.Index) = .empty;
    // var gen_scope: GenDir = .{
    //     .is_comptime = true,
    //     .parent = &top_scope.base,
    //     .decl_node_index = .root,
    //     .decl_line = 0,
    //     .astgen = &astgen,
    //     .instructions = &gz_instructions,
    //     .instructions_top = 0,
    // };
    // defer gz_instructions.deinit(gpa);

    const root_data = tree.nodes.items(.data)[0];
    _ = try astgen.expr(root_data.node);

    // const fatal = if (tree.errors.len == 0) fatal: {
    //     for (tree.rootDecls()) |member| {
    //         // containerMember(&gen_scope, &gen_scope.base, member) catch |err| switch (err) {
    //         //     error.OutOfMemory => |e| return e,
    //         //     error.AnalysisFail => break :fatal true, // Handled via compile_errors below.
    //         // };
    //     }
    // } else fatal: {
    //     try lowerAstErrors(&astgen);
    //     break :fatal true;
    // };

    // try astgen.extra.shrinkToLen(gpa);
    // try astgen.string_bytes.shrinkToLen(gpa);

    return .{
        .instructions = astgen.instructions.toOwnedSlice(),
    };

    // return .{
    //     .instructions = if (fatal) .empty else astgen.instructions.toOwnedSlice(),
    //     .string_bytes = astgen.string_bytes.toOwnedSliceAssert(),
    //     .extra = astgen.extra.toOwnedSliceAssert(),
    // };
}

fn expr(astgen: *AstGen, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;

    switch (tree.nodeTag(node)) {
        .root => unreachable, // Top-level declaration.
        // .bang_equal => return simpleBinOp(astgen, node, .cmp_neq),
        // .equal_equal => return simpleBinOp(astgen, node, .cmp_eq),
        // .add => return simpleBinOp(astgen, node, .add),
        // .sub => return simpleBinOp(astgen, node, .sub),
        // .mul => return simpleBinOp(astgen, node, .mul),
        // .div => return simpleBinOp(astgen, node, .div),
        // .mod => return simpleBinOp(astgen, node, .mod_rem),
        .number_literal => return numberLiteral(astgen, node, .positive),
        .string_literal => unreachable,
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
            0 => if (sign == .positive) try astgen.addInt(num) else return astgen.failTokNotes(
                num_token,
                "integer literal '-0' is ambiguous",
                .{},
                &.{
                    try astgen.errNoteTok(num_token, "use '0' for an integer zero", .{}),
                    try astgen.errNoteTok(num_token, "use '-0.0' for a floating-point signed zero", .{}),
                },
            ),
            else => try astgen.addInt(num),
        },
        .big_int => {
            // TODO(tzelon): support big int
            std.log.err("implement big_int", .{});
            unreachable;
        },
        .float => {
            const unsigned_float_number = std.fmt.parseFloat(f64, bytes) catch |err| switch (err) {
                error.InvalidCharacter => unreachable, // validated by tokenizer
            };
            const float_number = switch (sign) {
                .negative => -unsigned_float_number,
                .positive => unsigned_float_number,
            };
            // If the value fits into a f64 without losing any precision, store it that way.
            @setFloatMode(.strict);
            const smaller_float: f64 = @floatCast(float_number);
            const bigger_again: f128 = smaller_float;

            log.info("float: {}", .{float_number});
            log.info("smaller_float: {}", .{smaller_float});
            log.info("bigger_again: {}", .{bigger_again});
            if (std.math.isInf(float_number)) {
                return astgen.failTok(num_token, "float literal '{s}' overflows", .{bytes});
            }

            return astgen.addFloat(float_number);
        },
        .failure => |err| return astgen.failWithNumberError(err, num_token, bytes),
    };

    return result;
}

fn simpleBinOp(_: *AstGen, _: Ast.Node.Index, _: Dir.Inst.Tag) InnerError!Dir.Inst.Ref {
    unreachable;
}

const Scope = struct {
    tag: Tag,

    const Tag = enum { top, gen_zir, local_val };

    fn cast(base: *Scope, comptime T: type) ?*T {
        if (base.tag != T.base_tag) return null;
        return @alignCast(@fieldParentPtr("base", base));
    }

    fn unwrap(base: *Scope) Unwrapped {
        return switch (base.tag) {
            inline else => |t| @unionInit(
                Unwrapped,
                @tagName(t),
                @alignCast(@fieldParentPtr("base", base)),
            ),
        };
    }

    const Unwrapped = union(Tag) {
        top: *Top,
        gen_zir: *GenDir,
        local_val: *LocalVal,
    };

    const Top = struct {
        const base_tag: Tag = .top;
        base: Scope = .{ .tag = base_tag },
    };

    /// This is always a `const` local and importantly the `inst` is a value type, not a pointer.
    /// This structure lives as long as the AST generation of the Block
    /// node that contains the variable.
    const LocalVal = struct {
        const base_tag: Tag = .local_val;
        base: Scope = .{ .tag = base_tag },
        /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
        parent: *Scope,
        /// String table index.
        name: Dir.NullTerminatedString,
        inst: Dir.Inst.Ref,
        /// Source location of the corresponding variable declaration.
        token_src: Ast.TokenIndex,
    };
};

fn addInt(astgen: *AstGen, integer: u64) !Dir.Inst.Ref {
    return astgen.add(.{
        .tag = .int,
        .data = .{ .int = integer },
    });
}

fn addFloat(astgen: *AstGen, number: f64) !Dir.Inst.Ref {
    return astgen.add(.{
        .tag = .float,
        .data = .{ .float = number },
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
    // astgen.extra.deinit(gpa);
    // astgen.string_table.deinit(gpa);
    // astgen.string_bytes.deinit(gpa);
    // astgen.compile_errors.deinit(gpa);
    // astgen.imports.deinit(gpa);
    // astgen.scratch.deinit(gpa);
    // astgen.ref_table.deinit(gpa);
}

/// This is a temporary structure; references to it are valid only
/// while constructing a `Dir`.
const GenDir = struct {
    const base_tag: Scope.Tag = .gen_zir;
    base: Scope = .{ .tag = base_tag },
    /// Parents can be: `LocalVal`, `LocalPtr`, `GenDir`, `Defer`, `Namespace`.
    parent: *Scope,
    /// All `GenDir` scopes for the same DIR share this.
    astgen: *AstGen,
    /// Keeps track of the list of instructions in this scope. Possibly shared.
    /// Indexes to instructions in `astgen`.
    instructions: *std.ArrayList(Dir.Inst.Index),
    /// A sub-block may share its instructions ArrayList with containing GenZir,
    /// if use is strictly nested. This saves prior size of list for unstacking.
    instructions_top: usize,
    /// The containing decl AST node.
    decl_node_index: Ast.Node.Index,

    const unstacked_top = std.math.maxInt(usize);

    fn makeSubBlock(gz: *GenDir, scope: *Scope) GenDir {
        return .{
            .parent = scope,
            .astgen = gz.astgen,
            .instructions = gz.instructions,
            .instructions_top = gz.instructions.items.len,
        };
    }

    fn unstack(gz: *GenDir) void {
        gz.instructions.items.len = gz.instructions_top;
    }

    fn instructionsSlice(self: *const GenDir) []Dir.Inst.Index {
        return if (self.instructions_top == unstacked_top)
            &[0]Dir.Inst.Index{}
        else
            self.instructions.items[self.instructions_top..];
    }

    /// Note that this returns a `Dir.Inst.Index` not a ref.
    /// Does *not* append the block instruction to the scope.
    /// Leaves the `payload_index` field undefined. Use `setDeclaration` to finalize.
    fn makeDeclaration(gz: *GenDir, node: Ast.Node.Index) !Dir.Inst.Index {
        const new_index: Dir.Inst.Index = @enumFromInt(gz.astgen.instructions.len);
        try gz.astgen.instructions.append(gz.astgen.gpa, .{
            .tag = .declaration,
            .data = .{ .declaration = .{
                .src_node = node,
                .payload_index = undefined,
            } },
        });
        return new_index;
    }
};

fn lowerAstErrors(_: *AstGen) error{OutOfMemory}!void {
    unreachable;
}

fn failWithNumberError(astgen: *AstGen, err: std.zig.number_literal.Error, token: Ast.TokenIndex, bytes: []const u8) InnerError {
    const is_float = std.mem.findScalar(u8, bytes, '.') != null;
    switch (err) {
        .leading_zero => if (is_float) {
            return astgen.failTok(token, "number '{s}' has leading zero", .{bytes});
        } else {
            return astgen.failTokNotes(token, "number '{s}' has leading zero", .{bytes}, &.{
                try astgen.errNoteTok(token, "use '0o' prefix for octal literals", .{}),
            });
        },
        .digit_after_base => return astgen.failTok(token, "expected a digit after base prefix", .{}),
        .upper_case_base => |i| return astgen.failOff(token, @intCast(i), "base prefix must be lowercase", .{}),
        .invalid_float_base => |i| return astgen.failOff(token, @intCast(i), "invalid base for float literal", .{}),
        .repeated_underscore => |i| return astgen.failOff(token, @intCast(i), "repeated digit separator", .{}),
        .invalid_underscore_after_special => |i| return astgen.failOff(token, @intCast(i), "expected digit before digit separator", .{}),
        .invalid_digit => |info| return astgen.failOff(token, @intCast(info.i), "invalid digit '{c}' for {s} base", .{ bytes[info.i], @tagName(info.base) }),
        .invalid_digit_exponent => |i| return astgen.failOff(token, @intCast(i), "invalid digit '{c}' in exponent", .{bytes[i]}),
        .duplicate_exponent => |i| return astgen.failOff(token, @intCast(i), "duplicate exponent", .{}),
        .exponent_after_underscore => |i| return astgen.failOff(token, @intCast(i), "expected digit before exponent", .{}),
        .special_after_underscore => |i| return astgen.failOff(token, @intCast(i), "expected digit before '{c}'", .{bytes[i]}),
        .trailing_special => |i| return astgen.failOff(token, @intCast(i), "expected digit after '{c}'", .{bytes[i - 1]}),
        .trailing_underscore => |i| return astgen.failOff(token, @intCast(i), "trailing digit separator", .{}),
        .duplicate_period => unreachable, // Validated by tokenizer
        .invalid_character => unreachable, // Validated by tokenizer
        .invalid_exponent_sign => |i| {
            assert(bytes.len >= 2 and bytes[0] == '0' and bytes[1] == 'x'); // Validated by tokenizer
            return astgen.failOff(token, @intCast(i), "sign '{c}' cannot follow digit '{c}' in hex base", .{ bytes[i], bytes[i - 1] });
        },
        .period_after_exponent => |i| return astgen.failOff(token, @intCast(i), "unexpected period after exponent", .{}),
    }
}

fn failTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime fmt: []const u8,
    args: anytype,
) InnerError {
    _ = astgen;
    std.debug.print("error at token {d}: " ++ fmt ++ "\n", .{token} ++ args);
    return error.AnalysisFail;
}

fn failOff(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    offset: u32,
    comptime fmt: []const u8,
    args: anytype,
) InnerError {
    _ = astgen;
    std.debug.print("error at token {d}+{d}: " ++ fmt ++ "\n", .{ token, offset } ++ args);
    return error.AnalysisFail;
}

fn failTokNotes(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime fmt: []const u8,
    args: anytype,
    notes: []const []const u8,
) InnerError {
    std.debug.print("error at token {d}: " ++ fmt ++ "\n", .{token} ++ args);
    for (notes) |note| {
        std.debug.print("  note: {s}\n", .{note});
        astgen.gpa.free(note);
    }
    return error.AnalysisFail;
}

fn errNoteTok(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    comptime fmt: []const u8,
    args: anytype,
) ![]const u8 {
    _ = token;
    return std.fmt.allocPrint(astgen.gpa, fmt, args);
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
            .float => try std.testing.expectEqual(exp.data.float, data.float),
        }
    }

    dir.dump();
}

test "int literal" {
    try expectDir("42", &.{
        .{ .tag = .int, .data = .{ .int = 42 } },
    });
}

test "underscore separator" {
    try expectDir("42_2", &.{
        .{ .tag = .int, .data = .{ .int = 422 } },
    });
}

test "float literal" {
    try expectDir("2.2", &.{
        .{ .tag = .float, .data = .{ .float = 2.2 } },
    });
}
