//! generates Middle Intermediate Representation
//! using the visitor pattern

const AstGen = @This();

const Ast = @import("Ast.zig");
const Node = Ast.Node;

const Dir = @import("Dir.zig");

const std = @import("std");
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
        .number_literal => return numberLiteral(astgen, node),
        .string_literal => unreachable,
        else => {
            unreachable;
        },
    }
}

const Sign = enum { negative, positive };

fn numberLiteral(astgen: *AstGen, node: Ast.Node.Index) InnerError!Dir.Inst.Ref {
    const tree = astgen.tree;
    const num_token = tree.nodeMainToken(node);
    const bytes = tree.tokenSlice(num_token);

    const result: Dir.Inst.Ref = switch (std.zig.parseNumberLiteral(bytes)) {
        .int => |num| try astgen.addInt(num),
        // .failure => |err| return astgen.failWithNumberError(err, num_token, bytes),
        else => {
            unreachable;
        },
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

test "output dir" {
    const gpa = std.testing.allocator;

    var tree = try Ast.parse(gpa, "42_2");
    defer tree.deinit(gpa);

    var dir = try AstGen.generate(gpa, tree);
    defer dir.deinit(gpa);

    const tags = dir.instructions.items(.tag);
    const datas = dir.instructions.items(.data);

    try std.testing.expectEqual(@as(usize, 1), dir.instructions.len);
    try std.testing.expectEqual(Dir.Inst.Tag.int, tags[0]);
    try std.testing.expectEqual(@as(u64, 422), datas[0].int);

    for (tags, datas, 0..) |tag, data, i| switch (tag) {
        .int => std.debug.print("%{d} = int {d}\n", .{ i, data.int }),
    };
}
