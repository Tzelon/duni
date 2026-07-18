const Dir = @import("../Dir.zig");
const Ast = @import("../Ast.zig");

const Scope = @This();

tag: Tag,

pub fn cast(base: *Scope, comptime T: type) ?*T {
    if (base.tag != T.base_tag)
        return null;

    return @alignCast(@fieldParentPtr("base", base));
}

pub fn parent(base: *Scope) ?*Scope {
    return switch (base.tag) {
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
    local_val: *LocalVal,
    top: *Top,
};

pub const Tag = enum {
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

pub const Top = struct {
    const base_tag: Scope.Tag = .top;
    base: Scope = Scope{ .tag = base_tag },
};
