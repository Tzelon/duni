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

const builtin = @import("builtin");

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");

instructions: std.MultiArrayList(Inst).Slice,
/// The meaning of this data is determined by `Inst.Tag` value.
/// The first few indexes are reserved. See `ExtraIndex` for the values.
extra: []u32,

// TODO: temp until we have body tag
main_body_start: u32,
main_body_len: u32,

/// These are untyped instructions generated from an Abstract Syntax Tree.
/// The data here is immutable because it is possible to have multiple
/// analyses on the same DIR happening at the same time.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        int,
        /// Arithmetic addition, asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        add,
        /// Arithmetic subtraction. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        sub,
        /// Arithmetic multiplication. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mul,
        /// Implements the `@divTrunc` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div,
        /// Arithmetic negation. Asserts no integer overflow.
        /// Same as sub with a lhs of 0, split into a separate instruction to save memory.
        /// Uses `un_node`.
        negate,
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
        number_type,
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
        int: u64,

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

        bin: Bin,
    };

    // Make sure we don't accidentally add a field to make this union
    // bigger than expected. Note that in Debug builds, Zig is allowed
    // to insert a secret field for safety checks.
    comptime {
        if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) {
            assert(@sizeOf(Data) == 8);
        }
    }

    /// The meaning of these operands depends on the corresponding `Tag`.
    pub const Bin = struct {
        lhs: Ref,
        rhs: Ref,
    };
};

fn ExtraData(comptime T: type) type {
    return struct { data: T, end: usize };
}

/// Returns the requested data, as well as the new index which is at the start of the
/// trailers for the object.
pub fn extraData(code: Dir, comptime T: type, index: usize) ExtraData(T) {
    const info = @typeInfo(T).@"struct";
    var i: usize = index;
    var result: T = undefined;
    inline for (info.fields) |field| {
        @field(result, field.name) = switch (field.type) {
            u32 => code.extra[i],

            Inst.Ref,
            Inst.Index,
            Ast.Node.Index,
            => @enumFromInt(code.extra[i]),

            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @enumFromInt(@as(i32, @bitCast(code.extra[i]))),

            else => @compileError("bad field type"),
        };
        i += 1;
    }
    return .{
        .data = result,
        .end = i,
    };
}

pub fn bodySlice(dir: Dir, start: usize, len: usize) []Inst.Index {
    return @ptrCast(dir.extra[start..][0..len]);
}

pub fn deinit(code: *Dir, gpa: Allocator) void {
    code.instructions.deinit(gpa);
    gpa.free(code.extra);
    code.* = undefined;
}
