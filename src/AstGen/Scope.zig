const std = @import("std");
const Allocator = std.mem.Allocator;

const Dir = @import("../Dir.zig");
const Ast = @import("../Ast.zig");
const GenDir = @import("../AstGen.zig").GenDir;

const Scope = @This();

tag: Tag,

pub fn cast(base: *Scope, comptime T: type) ?*T {
    if (base.tag != T.base_tag)
        return null;

    return @alignCast(@fieldParentPtr("base", base));
}

pub fn parent(base: *Scope) ?*Scope {
    return switch (base.tag) {
        .namespace => base.cast(Namespace).?.parent,
        .local_val => base.cast(LocalVal).?.parent,
        .top => null,
    };
}

pub fn unwrap(base: *Scope) Unwrapped {
    return switch (base.tag) {
        inline else => |tag| @unionInit(
            Unwrapped,
            @tagName(tag),
            @alignCast(@fieldParentPtr("base", base)),
        ),
    };
}

pub const Cursor = struct {
    tip: *Scope,
};

pub const Unwrapped = union(Tag) {
    namespace: *Namespace,
    local_val: *LocalVal,
    top: *Top,
};

pub const Tag = enum {
    namespace,
    local_val,
    top,
};

/// The category of identifier. These tag names are user-visible in compile errors.
const IdCat = enum {
    @"local variable",
};

/// This is always a `const` local and importantly the `inst` is a value type, not a pointer.
/// This structure lives as long as the AST generation of the Block
/// node that contains the variable.
pub const LocalVal = struct {
    const base_tag: Tag = .local_val;
    base: Scope = Scope{ .tag = base_tag },
    /// Parents can be: `LocalVal`, `Namespace`.
    parent: *Scope,
    inst: Dir.Inst.Ref,
    /// Source location of the corresponding variable declaration.
    token_src: Ast.TokenIndex,
    /// String table index.
    name: Dir.NullTerminatedString,
    id_cat: IdCat,
};

/// Represents a global scope that has any number of declarations in it.
/// Each declaration has this as the parent scope.
pub const Namespace = struct {
    const base_tag: Tag = .namespace;
    base: Scope = Scope{ .tag = base_tag },

    /// Parents can be: `LocalVal`, `GenDir`, `Namespace`.
    parent: *Scope,
    /// Maps string table index to the source location of declaration,
    /// for the purposes of reporting name shadowing compile errors.
    decls: std.AutoHashMapUnmanaged(Dir.NullTerminatedString, Ast.Node.Index) = .empty,
    node: Ast.Node.Index,
    // inst: Dir.Inst.Index,
    //
    /// The astgen scope containing this namespace.
    /// Only valid during astgen.
    // declaring_gd: ?*GenDir,
    //
    // /// Set of captures used by this namespace.
    // captures: std.array_hash_map.Auto(Zir.Inst.Capture, Zir.NullTerminatedString) = .empty,
    //
    pub fn deinit(self: *Namespace, gpa: Allocator) void {
        self.decls.deinit(gpa);
        // self.captures.deinit(gpa);
        self.* = undefined;
    }
};

pub const Top = struct {
    const base_tag: Scope.Tag = .top;
    base: Scope = Scope{ .tag = base_tag },
};
