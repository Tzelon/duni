//! Duni Intermediate Representation.
//!
//! AstGen.zig converts AST nodes to these untyped IR instructions. Next,
//! Sema.zig processes these into AIR.
//! The minimum amount of information needed to represent a list of DIR instructions.
//! Once this structure is completed, it can be used to generate AIR, followed by
//! machine code, without any memory access into the AST tree token list, node list,
//! or source bytes. Exceptions include:
//!  * Compile errors, which may need to reach into these data structures to
//!    create a useful report.

const Dir = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

instructions: std.MultiArrayList(Inst).Slice,

/// These are untyped instructions generated from an Abstract Syntax Tree.
/// The data here is immutable because it is possible to have multiple
/// analyses on the same DIR happening at the same time.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        /// An integer literal. Uses the `int` union field.
        int,
        float,
        // cmp_neq,
        // cmp_eq,
        // add,
        // sub,
        // mul,
        // div,
        // mod_rem,
    };

    /// The position of a DIR instruction within the `Dir` instructions array.
    pub const Index = enum(u32) {
        /// DIR is structured so that the outermost "main" struct of any file
        /// is always at index 0.
        main_struct_inst = 0,
        _,

        pub fn toRef(i: Index) Inst.Ref {
            return @enumFromInt(Ref.static_len + @intFromEnum(i));
        }

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    pub const OptionalIndex = enum(u32) {
        main_struct_inst = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }
    };

    /// A reference to a DIR instruction, or to an InternPool index, or neither.
    ///
    /// If the integer tag value is < `static_len`, then it corresponds to an
    /// InternPool index. Otherwise, this refers to a DIR instruction.
    ///
    /// The tag type is specified so that it is safe to bitcast between `[]u32`
    /// and `[]Ref`.
    pub const Ref = enum(u32) {
        /// This Ref does not correspond to any DIR instruction or constant
        /// value and may instead be used as a sentinel to indicate null.
        none = std.math.maxInt(u32),
        _,

        pub const static_len = @typeInfo(@This()).@"enum".fields.len - 1;

        pub fn toIndex(inst: Ref) ?Index {
            assert(inst != .none);
            const ref_int = @intFromEnum(inst);
            if (ref_int >= static_len) {
                return @enumFromInt(ref_int - static_len);
            } else {
                return null;
            }
        }

        pub fn toIndexAllowNone(inst: Ref) ?Index {
            if (inst == .none) return null;
            return toIndex(inst);
        }
    };

    /// All instructions have an 8-byte payload, which is contained within
    /// this union. `Tag` determines which union field is active, as well as
    /// how to interpret the data within.
    pub const Data = union {
        /// Used for unary operators, with an AST node source location.
        un_node: struct {
            /// Offset from Decl AST node index.
            src_node: Ast.Node.Offset,
            /// The meaning of this operand depends on the corresponding `Tag`.
            operand: Ref,
        },
        pl_node: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: Ast.Node.Offset,
            /// index into extra.
            /// `Tag` determines what lives there.
            payload_index: u32,
        },
        /// Offset from Decl AST node index.
        node: Ast.Node.Offset,
        int: u64,
        float: f64,
    };
};

pub fn dump(dir: *const Dir) void {
    const tags = dir.instructions.items(.tag);
    const datas = dir.instructions.items(.data);

    for (tags, datas, 0..) |tag, data, i| switch (tag) {
        .int => std.debug.print("%{d} = int {d}\n", .{ i, data.int }),
        .float => std.debug.print("%{d} = float {d}\n", .{ i, data.float }),
    };
}

pub fn deinit(code: *Dir, gpa: Allocator) void {
    code.instructions.deinit(gpa);
    // gpa.free(code.string_bytes);
    // gpa.free(code.extra);
    code.* = undefined;
}
