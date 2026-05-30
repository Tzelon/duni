//! generates Middle Intermediate Representation
//! using the visitor pattern

const AstGen = @This();

const Ast = @import("ast.zig");
const Node = Ast.Node;

const Dir = @import("dir.zig");

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
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

const InnerError = error{ OutOfMemory, AnalysisFail };

pub fn generate(gpa: Allocator, tree: Ast) Allocator.Error!Dir {
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
        for (tree.rootDecls()) |member| {
            containerMember(&gen_scope, &gen_scope.base, member) catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                error.AnalysisFail => break :fatal true, // Handled via compile_errors below.
            };
        }
    } else fatal: {
        try lowerAstErrors(&astgen);
        break :fatal true;
    };

    try astgen.extra.shrinkToLen(gpa);
    try astgen.string_bytes.shrinkToLen(gpa);

    return .{
        .instructions = if (fatal) .empty else astgen.instructions.toOwnedSlice(),
        .string_bytes = astgen.string_bytes.toOwnedSliceAssert(),
        .extra = astgen.extra.toOwnedSliceAssert(),
    };
}

const ContainerMemberResult = union(enum) { decl, field: Ast.full.ContainerField };
fn containerMember(gz: *GenZir, scope: *Scope, member_node: Ast.Node.Index) InnerError!ContainerMemberResult {
    const astgen = gz.astgen;
    const tree = astgen.tree;

    switch (tree.nodeTag(member_node)) {
        .fn_decl,
        .fn_proto,
        => {
            var buf: [1]Ast.Node.Index = undefined;
            const full = tree.fullFnProto(&buf, member_node).?;

            const body: Ast.Node.OptionalIndex = if (tree.nodeTag(member_node) == .fn_decl)
                tree.nodeData(member_node).node_and_node[1].toOptional()
            else
                .none;
            try astgen / fnDecl(astgen, scope, member_node, body, full);
        },
        else => unreachable,
    }
}

fn fnDecl(
    astgen: *AstGen,
    gz: *GenZir,
    scope: *Scope,
    decl_node: Ast.Node.Index,
    body_node: Ast.Node.OptionalIndex,
    fn_proto: Ast.full.FnProto,
) InnerError!void {
    const tree = astgen.tree;

    //TODO(tzelon): check for missing function name
    // zig check it in scanContainer()
    const fn_name_token = fn_proto.name_token.?;

    // We insert this at the beginning so that its instruction index marks the
    // start of the top level declaration.
    const decl_inst = try gz.makeDeclaration(fn_proto.ast.proto_node);
    // astgen.advanceSourceCursorToNode(decl_node);

    const return_type = fn_proto.ast.return_type.unwrap().?;

    var value_gz: GenZir = .{
        .decl_node_index = fn_proto.ast.proto_node,
        .parent = scope,
        .astgen = astgen,
        .instructions = gz.instructions,
        .instructions_top = gz.instructions.items.len,
    };
    defer value_gz.unstack();

    try astgen.fnDeclInner(&value_gz, &value_gz.base, decl_inst, decl_node, body_node.unwrap().?, fn_proto);

    try setDeclaration(decl_inst, .{
        .kind = .@"const",
        .name = try astgen.identAsString(fn_name_token),
        .value_gz = &value_gz,
    });
}

fn fnDeclInner(
    astgen: *AstGen,
    decl_gz: *GenZir,
    scope: *Scope,
    decl_inst: Dir.Inst.Index,
    decl_node: Ast.Node.Index,
    body_node: Ast.Node.Index,
    fn_proto: Ast.full.FnProto,
) InnerError!void {}

// Helpers

// String Helpers

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

/// Given an identifier token, obtain the string for it  and append the string to `buf`.
/// See also `identifierTokenString` and `parseStrLit`.
fn appendIdentStr(
    astgen: *AstGen,
    token: Ast.TokenIndex,
    buf: *ArrayList(u8),
) InnerError!void {
    const tree = astgen.tree;
    assert(tree.tokenTag(token) == .identifier);
    const ident_name = tree.tokenSlice(token);
    const start = buf.items.len;
    try astgen.parseStrLit(token, buf, ident_name, 1);
    const slice = buf.items[start..];
    if (mem.findScalar(u8, slice, 0) != null) {
        return astgen.failTok(token, "identifier cannot contain null bytes", .{});
    } else if (slice.len == 0) {
        return astgen.failTok(token, "identifier cannot be empty", .{});
    }
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
    /// The containing decl AST node.
    decl_node_index: Ast.Node.Index,

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

    /// Note that this returns a `Dir.Inst.Index` not a ref.
    /// Does *not* append the block instruction to the scope.
    /// Leaves the `payload_index` field undefined. Use `setDeclaration` to finalize.
    fn makeDeclaration(gz: *GenZir, node: Ast.Node.Index) !Dir.Inst.Index {
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

/// Sets all extra data for a `declaration` instruction.
/// Unstacks  `value_gz`.
fn setDeclaration(
    decl_inst: Dir.Inst.Index,
    args: struct {
        // kind: Dir.Inst.Declaration.Unwrapped.Kind,
        name: Dir.NullTerminatedString,
        /// Must be stacked on `addrspace_gz` and have nothing stacked on top of it.
        value_gz: *GenZir,
    },
) !void {
    const astgen = args.value_gz.astgen;
    const gpa = astgen.gpa;

    const value_body = args.value_gz.instructionsSlice();

    const has_name = args.name != .empty;
    const has_value_body = value_body.len != 0;

    // TODO(tzelon) should we check we have a body?
    // assert(id.hasValueBody() == has_value_body);

    const value_len = astgen.countBodyLenAfterFixups(value_body);

    const need_extra: usize =
        @as(usize, @intFromBool(id.hasName())) +
        @as(usize, @intFromBool(id.hasValueBody())) +
        value_len;

    try astgen.extra.ensureUnusedCapacity(gpa, need_extra);

    const extra: Zir.Inst.Declaration = .{
        .src_hash_0 = src_hash_arr[0],
        .src_hash_1 = src_hash_arr[1],
        .src_hash_2 = src_hash_arr[2],
        .src_hash_3 = src_hash_arr[3],
        .flags_0 = flags_arr[0],
        .flags_1 = flags_arr[1],
    };
    astgen.instructions.items(.data)[@intFromEnum(decl_inst)].declaration.payload_index =
        astgen.addExtraAssumeCapacity(extra);

    if (id.hasName()) {
        astgen.extra.appendAssumeCapacity(@intFromEnum(args.name));
    }
    if (id.hasValueBody()) {
        astgen.extra.appendAssumeCapacity(value_len);
    }

    astgen.appendBodyWithFixups(value_body);

    args.value_gz.unstack();
}

fn lowerAstErrors(_: *AstGen) error{OutOfMemory}!void {
    unreachable;
}
