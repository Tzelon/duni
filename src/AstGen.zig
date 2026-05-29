//! generates Middle Intermediate Representation
//! using the visitor pattern

const AstGen = @This();

const Ast = @import("ast.zig");
const Node = Ast.Node;

const Dir = @import("dir.zig");

const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const StringIndexAdapter = std.hash_map.StringIndexAdapter;
const StringIndexContext = std.hash_map.StringIndexContext;

gpa: Allocator,
tree: *const Ast,
instructions: std.MultiArrayList(Dir.Inst) = .{},
extra: ArrayList(u32) = .empty,
string_bytes: ArrayList(u8) = .empty,
string_table: std.HashMapUnmanaged(u32, void, StringIndexContext, std.hash_map.default_max_load_percentage) = .empty,
/// Used for temporary allocations; freed after AstGen is complete.
/// The resulting ZIR code has no references to anything in this arena.
arena: Allocator,

pub fn generate(gpa: Allocator, tree: Ast) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    var astgen = AstGen{ .tree = &tree, .arena = arena.allocator(), .gpa = gpa };
    defer astgen.deinit(gpa);

    // String table index 0 is reserved for `NullTerminatedString.empty`.
    try astgen.string_bytes.append(gpa, 0);

    // We expect at least as many DIR instructions and extra data items
    // as AST nodes.
    try astgen.instructions.ensureTotalCapacity(gpa, tree.nodes.len);

    var top_scope: Scope.Top = .{};

    var gz_instructions: std.ArrayList(Dir.Inst.Index) = .empty;
    var gen_scope: GenZir = .{
        .is_comptime = true,
        .parent = &top_scope.base,
        .decl_node_index = .root,
        .decl_line = 0,
        .astgen = &astgen,
        .instructions = &gz_instructions,
        .instructions_top = 0,
    };
    defer gz_instructions.deinit(gpa);

    const fatal = if (tree.errors.len == 0) fatal: {
        for (tree.rootDecls()) |m| {
            try expr_or_decl(&gen_scope, &gen_scope.base, m);
        }
    };

    try astgen.extra.shrinkToLen(gpa);
    try astgen.string_bytes.shrinkToLen(gpa);

    return .{
        .instructions = if (fatal) .empty else astgen.instructions.toOwnedSlice(),
        .string_bytes = astgen.string_bytes.toOwnedSliceAssert(),
        .extra = astgen.extra.toOwnedSliceAssert(),
    };
}

fn deinit(self: *AstGen, gpa: Allocator) void {
    self.instructions.deinit(gpa);
    self.extra.deinit(gpa);
    self.string_table.deinit(gpa);
    self.string_bytes.deinit(gpa);
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
        gen_zir: *GenZir,
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

/// This is a temporary structure; references to it are valid only
/// while constructing a `Zir`.
const GenZir = struct {
    const base_tag: Scope.Tag = .gen_zir;
    base: Scope = .{ .tag = base_tag },
    /// Parents can be: `LocalVal`, `LocalPtr`, `GenZir`, `Defer`, `Namespace`.
    parent: *Scope,
    /// All `GenZir` scopes for the same ZIR share this.
    astgen: *AstGen,
    /// Keeps track of the list of instructions in this scope. Possibly shared.
    /// Indexes to instructions in `astgen`.
    instructions: *std.ArrayList(Dir.Inst.Index),
    /// A sub-block may share its instructions ArrayList with containing GenZir,
    /// if use is strictly nested. This saves prior size of list for unstacking.
    instructions_top: usize,

    const unstacked_top = std.math.maxInt(usize);

    fn makeSubBlock(gz: *GenZir, scope: *Scope) GenZir {
        return .{
            .parent = scope,
            .astgen = gz.astgen,
            .instructions = gz.instructions,
            .instructions_top = gz.instructions.items.len,
        };
    }

    fn unstack(gz: *GenZir) void {
        gz.instructions.items.len = gz.instructions_top;
    }

    fn instructionsSlice(self: *const GenZir) []Dir.Inst.Index {
        return if (self.instructions_top == unstacked_top)
            &[0]Dir.Inst.Index{}
        else
            self.instructions.items[self.instructions_top..];
    }
};
