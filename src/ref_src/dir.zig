//! Duni Intermediate Representation.
//!
//! Astgen.zig converts AST nodes to these untyped IR instructions. Next,
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

const Ast = @import("ast.zig");

/// These are untyped instructions generated from an Abstract Syntax Tree.
/// The data here is immutable because it is possible to have multiple
/// analyses on the same ZIR happening at the same time.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    /// These names are used directly as the instruction names in the text format.
    /// See `data_field_map` for a list of which `Data` fields are used by each `Tag`.
    pub const Tag = enum(u8) {
        /// Arithmetic addition, asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        add,
        /// Arithmetic subtraction. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        sub,
        /// Arithmetic multiplication. Asserts no integer overflow.
        /// Uses the `pl_node` union field. Payload is `Bin`.
        mul,
        /// Implements the `@divExact` builtin.
        /// Uses the `pl_node` union field with payload `Bin`.
        div_exact,
    };

    /// The position of a ZIR instruction within the `Zir` instructions array.
    pub const Index = enum(u32) {
        /// ZIR is structured so that the outermost "main" struct of any file
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
        /// ZIR is structured so that the outermost "main" struct of any file
        /// is always at index 0.
        main_struct_inst = 0,
        none = std.math.maxInt(u32),
        _,

        pub fn unwrap(oi: OptionalIndex) ?Index {
            return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
        }
    };

    /// A reference to ZIR instruction, or to an InternPool index, or neither.
    ///
    /// If the integer tag value is < InternPool.static_len, then it
    /// corresponds to an InternPool index. Otherwise, this refers to a ZIR
    /// instruction.
    ///
    /// The tag type is specified so that it is safe to bitcast between `[]u32`
    /// and `[]Ref`.
    pub const Ref = enum(u32) {
        u0_type,
        u1_type,
        u8_type,
        i8_type,
        u16_type,
        i16_type,
        u29_type,
        u32_type,
        i32_type,
        u64_type,
        i64_type,
        u80_type,
        u128_type,
        i128_type,
        u256_type,
        usize_type,
        isize_type,
        c_char_type,
        c_short_type,
        c_ushort_type,
        c_int_type,
        c_uint_type,
        c_long_type,
        c_ulong_type,
        c_longlong_type,
        c_ulonglong_type,
        c_longdouble_type,
        f16_type,
        f32_type,
        f64_type,
        f80_type,
        f128_type,
        anyopaque_type,
        bool_type,
        void_type,
        type_type,
        anyerror_type,
        comptime_int_type,
        comptime_float_type,
        noreturn_type,
        anyframe_type,
        null_type,
        undefined_type,
        enum_literal_type,
        ptr_usize_type,
        ptr_const_comptime_int_type,
        manyptr_u8_type,
        manyptr_const_u8_type,
        manyptr_const_u8_sentinel_0_type,
        slice_const_u8_type,
        slice_const_u8_sentinel_0_type,
        manyptr_const_slice_const_u8_type,
        slice_const_slice_const_u8_type,
        optional_type_type,
        manyptr_const_type_type,
        slice_const_type_type,
        vector_8_i8_type,
        vector_16_i8_type,
        vector_32_i8_type,
        vector_64_i8_type,
        vector_1_u8_type,
        vector_2_u8_type,
        vector_4_u8_type,
        vector_8_u8_type,
        vector_16_u8_type,
        vector_32_u8_type,
        vector_64_u8_type,
        vector_2_i16_type,
        vector_4_i16_type,
        vector_8_i16_type,
        vector_16_i16_type,
        vector_32_i16_type,
        vector_4_u16_type,
        vector_8_u16_type,
        vector_16_u16_type,
        vector_32_u16_type,
        vector_2_i32_type,
        vector_4_i32_type,
        vector_8_i32_type,
        vector_16_i32_type,
        vector_4_u32_type,
        vector_8_u32_type,
        vector_16_u32_type,
        vector_2_i64_type,
        vector_4_i64_type,
        vector_8_i64_type,
        vector_2_u64_type,
        vector_4_u64_type,
        vector_8_u64_type,
        vector_1_u128_type,
        vector_2_u128_type,
        vector_1_u256_type,
        vector_4_f16_type,
        vector_8_f16_type,
        vector_16_f16_type,
        vector_32_f16_type,
        vector_2_f32_type,
        vector_4_f32_type,
        vector_8_f32_type,
        vector_16_f32_type,
        vector_2_f64_type,
        vector_4_f64_type,
        vector_8_f64_type,
        optional_noreturn_type,
        anyerror_void_error_union_type,
        adhoc_inferred_error_set_type,
        generic_poison_type,
        empty_tuple_type,
        undef,
        undef_bool,
        undef_usize,
        undef_u1,
        zero,
        zero_usize,
        zero_u1,
        zero_u8,
        one,
        one_usize,
        one_u1,
        one_u8,
        four_u8,
        negative_one,
        void_value,
        unreachable_value,
        null_value,
        bool_true,
        bool_false,
        empty_tuple,

        /// This Ref does not correspond to any ZIR instruction or constant
        /// value and may instead be used as a sentinel to indicate null.
        none = std.math.maxInt(u32),

        _,

        pub const static_len = @typeInfo(@This()).@"enum".field_names.len - 1;

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
        /// Used for `Tag.extended`. The extended opcode determines the meaning
        /// of the `small` and `operand` fields.
        extended: Extended.InstData,
        /// Used for unary operators, with an AST node source location.
        un_node: struct {
            /// Offset from Decl AST node index.
            src_node: Ast.Node.Offset,
            /// The meaning of this operand depends on the corresponding `Tag`.
            operand: Ref,
        },
        /// Used for unary operators, with a token source location.
        un_tok: struct {
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,
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
        pl_tok: struct {
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,
            /// index into extra.
            /// `Tag` determines what lives there.
            payload_index: u32,
        },
        /// For strings which may contain null bytes.
        str: struct {
            /// Offset into `string_bytes`.
            start: NullTerminatedString,
            /// Number of bytes in the string.
            len: u32,

            pub fn get(self: @This(), code: Dir) []const u8 {
                return code.string_bytes[@intFromEnum(self.start)..][0..self.len];
            }
        },
        str_tok: struct {
            /// Offset into `string_bytes`. Null-terminated.
            start: NullTerminatedString,
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,

            pub fn get(self: @This(), code: Dir) [:0]const u8 {
                return code.nullTerminatedString(self.start);
            }
        },
        /// Offset from Decl AST token index.
        tok: Ast.TokenOffset,
        /// Offset from Decl AST node index.
        node: Ast.Node.Offset,
        int: u64,
        float: f64,
        int_type: struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: Ast.Node.Offset,
            signedness: std.lang.Signedness,
            bit_count: u16,
        },
        @"unreachable": struct {
            /// Offset from Decl AST node index.
            /// `Tag` determines which kind of AST node this points to.
            src_node: Ast.Node.Offset,
        },
        /// Used for unary operators which reference an inst,
        /// with an AST node source location.
        inst_node: struct {
            /// Offset from Decl AST node index.
            src_node: Ast.Node.Offset,
            /// The meaning of this operand depends on the corresponding `Tag`.
            inst: Index,
        },
        str_op: struct {
            /// Offset into `string_bytes`. Null-terminated.
            str: NullTerminatedString,
            operand: Ref,

            pub fn getStr(self: @This(), zir: Dir) [:0]const u8 {
                return zir.nullTerminatedString(self.str);
            }
        },
        save_err_ret_index: struct {
            operand: Ref, // If error type (or .none), save new trace index
        },
        elem_val_imm: struct {
            /// The indexable value being accessed.
            operand: Ref,
            /// The index being accessed.
            idx: u32,
        },
        declaration: struct {
            /// This node provides a new absolute baseline node for all instructions within this struct.
            src_node: Ast.Node.Index,
            /// index into extra to a `Declaration` payload.
            payload_index: u32,
        },

        // Make sure we don't accidentally add a field to make this union
        // bigger than expected. Note that in Debug builds, Zig is allowed
        // to insert a secret field for safety checks.
        comptime {
            // if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) {
            //     assert(@sizeOf(Data) == 8);
            // }
        }
    };

    /// Rarer instructions are here; ones that do not fit in the 8-bit `Tag` enum.
    /// `noreturn` instructions may not go here; they must be part of the main `Tag` enum.
    pub const Extended = enum(u16) {
        /// A struct type definition. Contains references to ZIR instructions for
        /// the field types, defaults, and alignments.
        /// `operand` is payload index to `StructDecl`.
        /// `small` is `StructDecl.Small`.
        struct_decl,

        pub const InstData = struct {
            opcode: Extended,
            small: u16,
            operand: u32,
        };
    };

    /// Trailing: [body_len]Inst.Index   (the function body, lowered)
    pub const Declaration = struct {
        name: NullTerminatedString,
        body_len: u32,
    };
};

pub const NullTerminatedString = enum(u32) {
    empty = 0,
    _,
};
