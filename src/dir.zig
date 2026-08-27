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
/// In order to store references to strings in fewer bytes, we copy all
/// string bytes into here. String bytes can be null. It is up to whomever
/// is referencing the data here whether they want to store both index and length,
/// thus allowing null bytes, or store only index, and use null-termination. The
/// `string_bytes` array is agnostic to either usage.
/// Index 0 is reserved for special cases.
string_bytes: []u8,
/// The meaning of this data is determined by `Inst.Tag` value.
/// The first few indexes are reserved. See `ExtraIndex` for the values.
extra: []u32,

/// These are untyped instructions generated from an Abstract Syntax Tree.
/// The data here is immutable because it is possible to have multiple
/// analyses on the same DIR happening at the same time.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u8) {
        /// Uses a name to identify a Decl and uses it as a value.
        /// Uses the `str_tok` union field.
        decl_val,
        /// String Literal. Makes an anonymous Decl and then takes a pointer to it.
        /// Uses the `str` union field.
        str,
        /// Integer literal that fits in a u64. Uses the `int` union field.
        int,
        /// Arbitrary sized integer literal. Uses the `str` union field.
        int_big,
        /// A float literal that fits in a f64. Uses the float union value.
        float,
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
        /// `lhs == rhs`. Uses the `pl_node` union field. Payload is `Bin`.
        cmp_eq,
        /// `lhs != rhs`. Uses the `pl_node` union field. Payload is `Bin`.
        cmp_neq,
        /// `lhs < rhs`. Uses the `pl_node` union field. Payload is `Bin`.
        cmp_lt,
        /// `lhs <= rhs`. Uses the `pl_node` union field. Payload is `Bin`.
        cmp_lte,
        /// `lhs > rhs`. Uses the `pl_node` union field. Payload is `Bin`.
        cmp_gt,
        /// `lhs >= rhs`. Uses the `pl_node` union field. Payload is `Bin`.
        cmp_gte,
        /// Boolean negation: `!operand`. The operand must be a Bool.
        /// Uses `un_node`.
        bool_not,
        /// A block of code, which return a value.
        /// Uses the `pl_node` union field. Payload is `Block`.
        block,
        /// Return a value from a block.
        /// Uses the `break` union field.
        /// Uses the source information from previous instruction.
        @"break",
        /// A list of instructions which are analyzed in the parent context, without
        /// generating a runtime block. Must terminate with an "inline" variant of
        /// a noreturn instruction.
        /// Uses the `pl_node` union field. Payload is `Block`.
        block_inline,
        /// Return a value from a block. This instruction is used as the terminator
        /// of a `block_inline`. It allows using the return value from `Sema.analyzeBody`.
        /// This instruction may also be used when it is known that there is only one
        /// break instruction in a block, and the target block is the parent.
        /// Uses the `break` union field.
        break_inline,

        /// This instruction may only ever appear in the list of declarations for a
        /// namespace type, e.g. within a `module_decl` instruction. It represents a
        /// single source declaration (`fn`), containing the name,
        /// attributes, type, and value of the declaration.
        /// Uses the `declaration` union field. Payload is `Declaration`.
        declaration,

        /// Declares a parameter of the current function. Used for:
        /// * debug info
        /// * checking shadowing against declarations in the current namespace
        /// * parameter type expressions referencing other parameters
        /// These occur in the block outside a function body (the same block as
        /// contains the func instruction).
        /// Uses the `pl_tok` field. Token is the parameter name, payload is a `Param`.
        param,

        /// Function call.
        /// Uses the `pl_node` union field with payload `Call`.
        /// AST node is the function call.
        call,

        /// Sends control flow back to the function's callers, carrying the
        /// return value. Terminates a function value body (the implicit
        /// return of the body's last expression; an explicit `return`
        /// statement lands here too when it arrives).
        /// Uses the `un_node` union field.
        ret_node,

        /// Returns a function type, or a function instance, depending on whether
        /// the body_len is 0. Calling convention is auto.
        /// Uses the `pl_node` union field. `payload_index` points to a `Func`.
        func,

        /// The DIR instruction tag is one of the `Extended` ones.
        /// Uses the `extended` union field.
        extended,
    };

    /// Rarer instructions are here; ones that do not fit in the 8-bit `Tag` enum.
    /// `noreturn` instructions may not go here; they must be part of the main `Tag` enum.
    pub const Extended = enum(u16) {
        /// A module type definition. Contains references to DIR instructions for
        /// the field types.
        /// `operand` is payload index to `ModuleDecl`.
        /// `small` is `ModuleDecl.Small`.
        module_decl,

        pub const InstData = struct {
            opcode: Extended,
            small: u16,
            operand: u32,
        };
    };

    /// The position of a DIR instruction within the `Dir` instructions array.
    pub const Index = enum(u32) {
        /// DIR is structured so that the outermost "main" module of any file
        /// is always at index 0.
        main_module_inst = 0,
        _,

        pub fn toRef(i: Index) Inst.Ref {
            return @enumFromInt(Ref.static_len + @intFromEnum(i));
        }

        pub fn toOptional(i: Index) OptionalIndex {
            return @enumFromInt(@intFromEnum(i));
        }
    };

    pub const OptionalIndex = enum(u32) {
        main_module_inst = 0,
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
        // Kept in lock-step with `InternPool.Index`'s static members, in the
        // same order — `resolveInst` maps a Dir static Ref to the matching
        // InternPool Index by equal numeric value.
        u32_type,
        i32_type,
        u64_type,
        i64_type,
        f64_type,
        comptime_int_type,
        comptime_float_type,
        bool_type,
        string_type,
        void_type,
        type_type,

        zero,
        one,
        negative_one,
        bool_true,
        bool_false,
        void_value,

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
        float: f64,

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

        bin: Bin,

        @"break": struct {
            operand: Ref,
            /// Index of a `Break` payload.
            payload_index: u32,
        },

        /// For strings which may contain null bytes.
        str: struct {
            /// Offset into `string_bytes`.
            start: NullTerminatedString,
            /// Number of bytes in the string.
            len: u32,

            pub fn get(self: @This(), code: *const Dir) []const u8 {
                return code.string_bytes[@intFromEnum(self.start)..][0..self.len];
            }
        },

        /// For string which not contain null bytes, like identifiers
        str_tok: struct {
            /// Offset into `string_bytes`. Null-terminated.
            start: NullTerminatedString,
            /// Offset from Decl AST token index.
            src_tok: Ast.TokenOffset,

            pub fn get(self: @This(), code: *const Dir) [:0]const u8 {
                return code.nullTerminatedString(self.start);
            }
        },

        declaration: struct {
            /// This node provides a new absolute baseline node for all instructions within this module.
            src_node: Ast.Node.Index,
            /// index into extra to a `Declaration` payload.
            payload_index: u32,
        },
    };

    // Make sure we don't accidentally add a field to make this union
    // bigger than expected. Note that in Debug builds, Zig is allowed
    // to insert a secret field for safety checks.
    comptime {
        if (builtin.mode != .Debug and builtin.mode != .ReleaseSafe) {
            assert(@sizeOf(Data) == 8);
        }
    }

    pub const Break = struct {
        operand_src_node: Ast.Node.OptionalOffset,
        block_inst: Index,
    };

    /// The meaning of these operands depends on the corresponding `Tag`.
    pub const Bin = struct {
        lhs: Ref,
        rhs: Ref,
    };

    /// This data is stored inside extra, with trailing operands according to `body_len`.
    /// Each operand is an `Index`.
    pub const Block = struct {
        body_len: u32,
    };

    /// Trailing: inst: Index // for every body_len
    pub const Param = struct {
        /// Null-terminated string index.
        name: NullTerminatedString,
        type: Type,

        pub const Type = packed struct(u32) {
            /// The body contains the type of the parameter.
            body_len: u31,
            _: u1 = 0,
        };
    };

    /// Trailing:
    /// 0. name: NullTerminatedString      // if `flags.id.hasName()`
    /// 1. lib_name: NullTerminatedString  // if `flags.id.hasLibName()`
    /// 2. type_body_len: u32              // if `flags.id.hasTypeBody()`
    /// 3. value_body_len: u32             // if `flags.id.hasValueBody()`
    /// 4. type_body_inst: Zir.Inst.Index
    ///    - for each `type_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    /// 5. value_body_inst: Zir.Inst.Index
    ///    - for each `value_body_len`
    ///    - body to be exited via `break_inline` to this `declaration` instruction
    ///    - within this body, the `declaration` instruction refers to the resolved type from the type body
    pub const Declaration = struct {
        flags: Flags,

        pub const Unwrapped = struct {
            pub const Kind = enum(u1) {
                @"const",
                @"var",
            };

            pub const Linkage = enum(u1) {
                normal,
                @"extern",
            };

            src_node: Ast.Node.Index,

            kind: Kind,
            /// Always `.empty` for `kind` of `unnamed_test`, `.@"comptime"`
            name: NullTerminatedString,
            /// Always `.normal` for `kind != .@"const" and kind != .@"var"`.
            linkage: Linkage,
            /// Always `.empty` for `linkage != .@"extern"`.
            lib_name: NullTerminatedString,

            /// Always populated for `linkage == .@"extern".
            type_body: ?[]const Inst.Index,
            /// Always populated for `linkage != .@"extern".
            value_body: ?[]const Inst.Index,
        };

        pub const Flags = packed struct(u32) {
            kind: Unwrapped.Kind,
            linkage: Unwrapped.Linkage,
            has_name: bool,
            has_lib_name: bool,
            has_type_body: bool,
            has_value_body: bool,
            _: u26 = 0,
        };
    };

    /// This data is stored inside extra, with trailing operands according to `decls_len`, and `body_len`.
    /// Each operand is an `Index`.
    pub const ModuleDecl = struct {
        /// This node provides a new absolute baseline node for all instructions within this struct.
        src_node: Ast.Node.Index,
        decls_len: u32,
        body_len: u32,

        pub const Small = packed struct(u16) {
            _: u16 = 0,
        };
    };

    /// Trailing:
    /// if (ret_ty.body_len == 1) {
    ///   0. return_type: Ref
    /// }
    /// if (ret_ty.body_len > 1) {
    ///   1. return_type: Index // for each ret_ty.body_len
    /// }
    /// 2. body: Index // for each body_len
    pub const Func = struct {
        ret_ty: RetTy,
        /// Points to the block that contains the param instructions for this function.
        /// If this is a `declaration`, it refers to the declaration's value body.
        param_block: Index,
        body_len: u32,

        pub const RetTy = packed struct(u32) {
            /// 0 means `void`.
            /// 1 means the type is a simple `Ref`.
            /// Otherwise, the length of a trailing body.
            body_len: u31,
            _: u1 = 0,
        };
    };

    /// Stored inside extra, with trailing arguments according to `args_len`.
    pub const Call = struct {
        args_len: u32,
        callee: Ref,
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
            NullTerminatedString,
            => @enumFromInt(code.extra[i]),

            Ast.Node.Offset,
            Ast.Node.OptionalOffset,
            => @enumFromInt(@as(i32, @bitCast(code.extra[i]))),

            Inst.Declaration.Flags,
            Inst.Param.Type,
            Inst.Func.RetTy,
            => @bitCast(code.extra[i]),

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

/// TODO(tzelon): this will change we might not allow body in module
pub fn getModuleDecl(dir: Dir, module_decl: Inst.Index) UnwrappedModuleDecl {
    const inst_data = dir.instructions.get(@intFromEnum(module_decl));
    assert(inst_data.tag == .extended);
    assert(inst_data.data.extended.opcode == .module_decl);

    const extra = dir.extraData(Inst.ModuleDecl, inst_data.data.extended.operand);

    var extra_index = extra.end;
    const decls = dir.bodySlice(extra_index, extra.data.decls_len);
    extra_index += extra.data.decls_len;
    const body = dir.bodySlice(extra_index, extra.data.body_len);

    return .{
        .decls = decls,
        .body = body,
    };
}

const UnwrappedModuleDecl = struct {
    body: []const Inst.Index,
    decls: []const Inst.Index,
};

pub fn getDeclaration(dir: Dir, inst: Dir.Inst.Index) Inst.Declaration.Unwrapped {
    assert(dir.instructions.items(.tag)[@intFromEnum(inst)] == .declaration);
    const pl_node = dir.instructions.items(.data)[@intFromEnum(inst)].declaration;
    const extra = dir.extraData(Inst.Declaration, pl_node.payload_index);

    var extra_index = extra.end;

    const name: NullTerminatedString = if (extra.data.flags.has_name) name: {
        const name = dir.extra[extra_index];
        extra_index += 1;
        break :name @enumFromInt(name);
    } else .empty;

    const lib_name: NullTerminatedString = if (extra.data.flags.has_lib_name) lib_name: {
        const lib_name = dir.extra[extra_index];
        extra_index += 1;
        break :lib_name @enumFromInt(lib_name);
    } else .empty;

    const type_body_len: u32 = if (extra.data.flags.has_type_body) len: {
        const len = dir.extra[extra_index];
        extra_index += 1;
        break :len len;
    } else 0;
    const value_body_len: u32 = if (extra.data.flags.has_value_body) len: {
        const len = dir.extra[extra_index];
        extra_index += 1;
        break :len len;
    } else 0;

    const type_body = dir.bodySlice(extra_index, type_body_len);
    extra_index += type_body_len;
    const value_body = dir.bodySlice(extra_index, value_body_len);
    extra_index += value_body_len;

    return .{
        .src_node = pl_node.src_node,

        .kind = extra.data.flags.kind,
        .name = name,
        .linkage = extra.data.flags.linkage,
        .lib_name = lib_name,

        .type_body = if (type_body_len == 0) null else type_body,
        .value_body = if (value_body_len == 0) null else value_body,
    };
}

pub const NullTerminatedString = enum(u32) {
    empty = 0,
    _,
};

/// Given an index into `string_bytes` returns the null-terminated string found there.
pub fn nullTerminatedString(code: Dir, index: NullTerminatedString) [:0]const u8 {
    const slice = code.string_bytes[@intFromEnum(index)..];
    return slice[0..std.mem.findScalar(u8, slice, 0).? :0];
}

pub fn deinit(code: *Dir, gpa: Allocator) void {
    code.instructions.deinit(gpa);
    gpa.free(code.string_bytes);
    gpa.free(code.extra);
    code.* = undefined;
}
