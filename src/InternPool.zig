const InternPool = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Hash = std.hash.Wyhash;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;
const Limb = std.math.big.Limb;

const Dir = @import("Dir.zig");

const string = @import("string.zig");
const NullTerminatedString = string.NullTerminatedString;
const OptionalNullTerminatedString = string.OptionalNullTerminatedString;

// List of all constant items
items: std.MultiArrayList(Item) = .empty,
// A map to check if an item is already exists
map: std.hash_map.HashMapUnmanaged(Index, void, Context, std.hash_map.default_max_load_percentage) = .empty,

// parameter names, struct field names, enum tag names
extra: std.ArrayList(u32) = .empty,

limbs: std.ArrayList(Limb) = .empty,

// Flat byte buffer. Each interned string is followed by a 0 terminator.
string_bytes: std.ArrayListUnmanaged(u8) = .empty,
// Offset table. Entry `i` is the start of string `i` inside `string_bytes`.
strings: std.ArrayListUnmanaged(u32) = .empty,
// A map to check if a string is already exists
string_map: std.hash_map.HashMapUnmanaged(NullTerminatedString, void, NullTerminatedString.Context, std.hash_map.default_max_load_percentage) = .empty,

pub const Item = struct {
    tag: Tag,
    /// The doc comments on the respective Tag explain how to interpret this.
    data: u32,
};

/// Represents an index into `items`. It represents the canonical index
/// of a `Value` within this `InternPool`. The values are typed.
/// Two values which have the same type can be equality compared simply
/// by checking if their indexes are equal, provided they are both in
/// the same `InternPool`.
/// When adding a tag to this enum, consider adding a corresponding entry to
/// `primitives` in AstGen.zig.
pub const Index = enum(u32) {
    u32_type,
    i32_type,
    u64_type,
    i64_type,
    f64_type,
    comptime_int_type,
    comptime_float_type,
    string_type,
    void_type,
    type_type,

    /// `0` (comptime_int)
    zero,
    /// `1` (comptime_int)
    one,
    /// `-1` (comptime_int)
    negative_one,
    /// `()`
    void_value,

    /// Used by Air/Sema only.
    none = std.math.maxInt(u32),
    _,

    /// An array of `Index` existing within the `extra` array.
    /// This type exists to provide a struct with lifetime that is
    /// not invalidated when items are added to the `InternPool`.
    pub const Slice = struct {
        start: u32,
        len: u32,

        pub const empty: Slice = .{ .start = 0, .len = 0 };

        pub fn get(slice: Slice, ip: *const InternPool) []Index {
            return @ptrCast(ip.extra.items[slice.start..][0..slice.len]);
        }

        /// If `slice` is empty (`slice.len == 0`), returns `.none`.
        /// Otherwise, asserts that `index < slice.len`, and returns the value at `index`.
        pub fn getOrNone(slice: Slice, ip: *const InternPool, index: usize) Index {
            if (slice.len == 0) return .none;
            return slice.get(ip)[index];
        }
    };
};

pub const Key = union(enum) {
    simple_type: SimpleType,
    int: Key.Int,
    float: Float,
    string: NullTerminatedString,

    simple_value: SimpleValue,
    @"extern": Extern,
    func_type: FuncType,

    pub const Int = struct {
        ty: Index,
        storage: Storage,

        pub const Storage = union(enum) {
            u64: u64,
            i64: i64,
            big_int: BigIntConst,

            /// Big enough to fit any non-BigInt value
            pub const BigIntSpace = struct {
                /// The +1 is headroom so that operations such as incrementing once
                /// or decrementing once are possible without using an allocator.
                limbs: [(@sizeOf(u64) / @sizeOf(std.math.big.Limb)) + 1]std.math.big.Limb,
            };

            pub fn toBigInt(storage: Storage, space: *BigIntSpace) BigIntConst {
                return switch (storage) {
                    .big_int => |x| x,
                    inline .u64, .i64 => |x| BigIntMutable.init(&space.limbs, x).toConst(),
                };
            }
        };
    };

    pub const Float = struct {
        ty: Index,
        /// The storage used must match the size of the float type being represented.
        storage: Storage,

        pub const Storage = union(enum) {
            f64: f64,
            f32: f32,
        };
    };

    pub const FuncType = struct {
        param_types: Index.Slice,
        return_type: Index,

        pub fn eql(a: FuncType, b: FuncType, ip: *const InternPool) bool {
            return std.mem.eql(Index, a.param_types.get(ip), b.param_types.get(ip)) and
                a.return_type == b.return_type;
        }

        pub fn hash(self: FuncType, hasher: *Hash, ip: *const InternPool) void {
            for (self.param_types.get(ip)) |param_type| {
                std.hash.autoHash(hasher, param_type);
            }
            std.hash.autoHash(hasher, self.return_type);
        }
    };

    pub const Extern = struct {
        /// The name of the extern function; the wasm import's field name.
        name: NullTerminatedString,
        /// The extern function's type (its `func_type`).
        ty: Index,
        /// The wasm import's module name, if specified. `.none` defaults to
        /// `"host"` (see notes/functions.md). For example `extern "wasi..." fn`
        /// would carry the module string here.
        lib_name: OptionalNullTerminatedString,
    };

    /// Having `SimpleType` and `SimpleValue` in separate enums makes it easier to
    /// implement logic that only wants to deal with types because the logic can
    /// ignore all simple values. Note that technically, types are values.
    pub const SimpleType = enum(u32) {
        comptime_int = @intFromEnum(Index.comptime_int_type),
        comptime_float = @intFromEnum(Index.comptime_float_type),
        u32 = @intFromEnum(Index.u32_type),
        i32 = @intFromEnum(Index.i32_type),
        u64 = @intFromEnum(Index.u64_type),
        i64 = @intFromEnum(Index.i64_type),
        f64 = @intFromEnum(Index.f64_type),
        string = @intFromEnum(Index.string_type),
        void = @intFromEnum(Index.void_type),
        type = @intFromEnum(Index.type_type),
    };

    pub fn hash64(key: Key, ip: *const InternPool) u64 {
        const asBytes = std.mem.asBytes;
        const KeyTag = @typeInfo(Key).@"union".tag_type.?;
        const seed = @intFromEnum(@as(KeyTag, key));

        return switch (key) {
            inline .simple_type,
            .simple_value,
            => |x| Hash.hash(seed, asBytes(&x)),

            .int => |int| {
                var hasher = Hash.init(seed);
                // Canonicalize all integers by converting them to BigIntConst.
                var buffer: Key.Int.Storage.BigIntSpace = undefined;
                const big_int = int.storage.toBigInt(&buffer);

                std.hash.autoHash(&hasher, int.ty);
                std.hash.autoHash(&hasher, big_int.positive);
                for (big_int.limbs) |limb| std.hash.autoHash(&hasher, limb);
                return hasher.final();
            },

            .float => |float| {
                var hasher = Hash.init(seed);
                std.hash.autoHash(&hasher, float.ty);
                switch (float.storage) {
                    inline else => |val| std.hash.autoHash(
                        &hasher,
                        @as(@Int(.unsigned, @bitSizeOf(@TypeOf(val))), @bitCast(val)),
                    ),
                }
                return hasher.final();
            },

            .string => |str| Hash.hash(seed, asBytes(&str)),

            .@"extern" => |ext| Hash.hash(seed, asBytes(&ext)),

            .func_type => |func| {
                var hasher = Hash.init(seed);
                func.hash(&hasher, ip);
                return hasher.final();
            },
        };
    }

    pub fn eql(a: Key, b: Key, ip: *const InternPool) bool {
        const KeyTag = @typeInfo(Key).@"union".tag_type.?;
        const a_tag: KeyTag = a;
        const b_tag: KeyTag = b;
        if (a_tag != b_tag) return false;
        switch (a) {
            .simple_type => |a_info| {
                const b_info = b.simple_type;
                return a_info == b_info;
            },

            .simple_value => |a_info| {
                const b_info = b.simple_value;
                return a_info == b_info;
            },

            .int => |a_info| {
                const b_info = b.int;

                if (a_info.ty != b_info.ty)
                    return false;

                return switch (a_info.storage) {
                    .u64 => |aa| switch (b_info.storage) {
                        .u64 => |bb| aa == bb,
                        .i64 => |bb| aa == bb,
                        .big_int => |bb| bb.orderAgainstScalar(aa) == .eq,
                    },
                    .i64 => |aa| switch (b_info.storage) {
                        .u64 => |bb| aa == bb,
                        .i64 => |bb| aa == bb,
                        .big_int => |bb| bb.orderAgainstScalar(aa) == .eq,
                    },
                    .big_int => |aa| switch (b_info.storage) {
                        .u64 => |bb| aa.orderAgainstScalar(bb) == .eq,
                        .i64 => |bb| aa.orderAgainstScalar(bb) == .eq,
                        .big_int => |bb| aa.eql(bb),
                    },
                };
            },

            .float => |a_info| {
                const b_info = b.float;

                if (a_info.ty != b_info.ty)
                    return false;

                const StorageTag = @typeInfo(Key.Float.Storage).@"union".tag_type.?;
                assert(@as(StorageTag, a_info.storage) == @as(StorageTag, b_info.storage));

                switch (a_info.storage) {
                    inline else => |val, tag| {
                        const Bits = @Int(.unsigned, @bitSizeOf(@TypeOf(val)));
                        const a_bits: Bits = @bitCast(val);
                        const b_bits: Bits = @bitCast(@field(b_info.storage, @tagName(tag)));
                        return a_bits == b_bits;
                    },
                }
            },

            .string => |a_info| return a_info == b.string,

            .@"extern" => |a_info| return std.meta.eql(a_info, b.@"extern"),

            .func_type => |a_info| return a_info.eql(b.func_type, ip),
        }
    }
};

pub const SimpleValue = enum(u32) {
    void = @intFromEnum(Index.void_value),
};

pub fn init(ip: *InternPool, gpa: Allocator) !void {
    errdefer ip.deinit(gpa);

    // Seed the string offsets table, then pre-intern "" at index 0.
    try ip.strings.append(gpa, 0);
    const empty_str = try ip.getString(gpa, "");
    assert(empty_str == .empty);

    for (&string.static_strings, 0..) |slice, expected_index| {
        assert(try ip.getString(gpa, slice) == @as(NullTerminatedString, @enumFromInt(expected_index)));
    }

    // This inserts all the statically-known values into the intern pool in the
    // order expected.
    for (&static_keys, 0..) |key, key_index| switch (@as(Index, @enumFromInt(key_index))) {
        else => |expected_index| assert(try ip.get(gpa, key) == expected_index),
    };

    if (std.debug.runtime_safety) {
        // Sanity check.
        assert(ip.indexToKey(.void_value).simple_value == .void);
        // assert(ip.indexToKey(.bool_true).simple_value == .true);
        // assert(ip.indexToKey(.bool_false).simple_value == .false);
    }
}

pub fn get(ip: *InternPool, gpa: Allocator, key: Key) Allocator.Error!Index {
    const ctx: Context = .{ .ip = ip };
    const adapter: Adapter = .{ .ip = ip };

    const new_index: Index = @enumFromInt(ip.items.len);
    try ip.items.ensureUnusedCapacity(gpa, 1);
    const gop = try ip.map.getOrPutContextAdapted(gpa, key, adapter, ctx);

    // remove the key if something fails
    errdefer ip.map.removeByPtr(gop.key_ptr);
    if (gop.found_existing) return gop.key_ptr.*;

    switch (key) {
        .simple_type => |simple_type| {
            assert(@intFromEnum(simple_type) == ip.items.len);
            ip.items.appendAssumeCapacity(.{
                .tag = .simple_type,
                .data = 0, // avoid writing `undefined` bits to a file
            });
        },
        .simple_value => |simple_value| {
            assert(@intFromEnum(simple_value) == ip.items.len);
            ip.items.appendAssumeCapacity(.{
                .tag = .simple_value,
                .data = 0, // avoid writing `undefined` bits to a file
            });
        },
        .int => |int| b: {
            assert(ip.isIntegerType(int.ty));
            switch (int.ty) {
                .u32_type => switch (int.storage) {
                    .big_int => |big_int| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u32,
                            .data = big_int.toInt(u32) catch unreachable,
                        });
                        break :b;
                    },
                    inline .u64, .i64 => |x| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_u32,
                            .data = @as(u32, @intCast(x)),
                        });
                        break :b;
                    },
                },
                .i32_type => switch (int.storage) {
                    .big_int => |big_int| {
                        const casted = big_int.toInt(i32) catch unreachable;
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_i32,
                            .data = @as(u32, @bitCast(casted)),
                        });
                        break :b;
                    },
                    inline .u64, .i64 => |x| {
                        ip.items.appendAssumeCapacity(.{
                            .tag = .int_i32,
                            .data = @as(u32, @bitCast(@as(i32, @intCast(x)))),
                        });
                        break :b;
                    },
                },
                .comptime_int_type => switch (int.storage) {
                    .big_int => |big_int| {
                        if (big_int.toInt(u32)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_u32,
                                .data = casted,
                            });
                            break :b;
                        } else |_| {}
                        if (big_int.toInt(i32)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_i32,
                                .data = @as(u32, @bitCast(casted)),
                            });
                            break :b;
                        } else |_| {}
                    },
                    inline .u64, .i64 => |x| {
                        if (std.math.cast(u32, x)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_u32,
                                .data = casted,
                            });
                            break :b;
                        }
                        if (std.math.cast(i32, x)) |casted| {
                            ip.items.appendAssumeCapacity(.{
                                .tag = .int_comptime_int_i32,
                                .data = @as(u32, @bitCast(casted)),
                            });
                            break :b;
                        }
                    },
                },
                else => {},
            }
            // None of the 32-bit fast paths matched: store as limbs, whatever the storage variant.
            switch (int.storage) {
                .big_int => |big_int| {
                    const tag: Tag = if (big_int.positive) .int_positive else .int_negative;
                    try addInt(ip, gpa, int.ty, tag, big_int.limbs);
                },
                inline .u64, .i64 => |x| {
                    var buf: [2]Limb = undefined;
                    const big_int = BigIntMutable.init(&buf, x).toConst();
                    const tag: Tag = if (big_int.positive) .int_positive else .int_negative;
                    try addInt(ip, gpa, int.ty, tag, big_int.limbs);
                },
            }
        },
        .float => |float| {
            switch (float.ty) {
                .comptime_float_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_comptime_float,
                    .data = try addExtra(ip, gpa, Float64.pack(float.storage.f64)),
                }),
                .f64_type => ip.items.appendAssumeCapacity(.{
                    .tag = .float_f64,
                    .data = try addExtra(ip, gpa, Float64.pack(float.storage.f64)),
                }),
                else => unreachable,
            }
        },
        .string => |str| {
            ip.items.appendAssumeCapacity(.{ .tag = .string, .data = @intFromEnum(str) });
        },

        .@"extern" => |ext| {
            ip.items.appendAssumeCapacity(.{
                .tag = .@"extern",
                .data = try addExtra(ip, gpa, ext),
            });
        },

        .func_type => unreachable, // use getFuncType() instead
    }

    gop.key_ptr.* = new_index;
    return new_index;
}

pub fn getString(ip: *InternPool, gpa: Allocator, slice: []const u8) Allocator.Error!NullTerminatedString {
    const ctx: NullTerminatedString.Context = .{ .ip = ip };
    const adapter: NullTerminatedString.Adapter = .{ .ip = ip };

    // the new string is the position whose start-offset is already in `strings`.
    // after we push the new end-sentinel, this index's slice is well-defined.
    const new_index: NullTerminatedString = @enumFromInt(ip.strings.items.len - 1);

    try ip.strings.ensureUnusedCapacity(gpa, 1);
    try ip.string_bytes.ensureUnusedCapacity(gpa, slice.len + 1);

    const gop = try ip.string_map.getOrPutContextAdapted(gpa, slice, adapter, ctx);
    if (gop.found_existing) return gop.key_ptr.*;

    ip.string_bytes.appendSliceAssumeCapacity(slice);
    ip.string_bytes.appendAssumeCapacity(0);
    ip.strings.appendAssumeCapacity(@intCast(ip.string_bytes.items.len));

    gop.key_ptr.* = new_index;
    return new_index;
}

pub fn getFuncType(
    ip: *InternPool,
    gpa: Allocator,
    key: GetFuncTypeKey,
) Allocator.Error!Index {
    // Validate input parameters.
    assert(key.return_type != .none);
    for (key.param_types) |param_type| assert(param_type != .none);

    try ip.items.ensureUnusedCapacity(gpa, 1);

    // The strategy here is to add the function type unconditionally, then to
    // ask if it already exists, and if so, revert the lengths of the mutated
    // arrays. This is similar to what `getOrPutTrailingString` does.
    const prev_extra_len = ip.extra.items.len;
    const params_len: u32 = @intCast(key.param_types.len);

    try ip.extra.ensureUnusedCapacity(gpa, @typeInfo(Tag.TypeFunction).@"struct".fields.len +
        params_len);

    const func_type_extra_index = addExtraAssumeCapacity(ip, Tag.TypeFunction{
        .params_len = params_len,
        .return_type = key.return_type,
    });

    ip.extra.appendSliceAssumeCapacity(@ptrCast(key.param_types));
    errdefer ip.extra.items.len = prev_extra_len;

    const adapter: Adapter = .{ .ip = ip };
    const ctx: Context = .{ .ip = ip };
    const func_ty_key: Key = .{ .func_type = extraFuncType(ip, func_type_extra_index) };

    const gop = try ip.map.getOrPutContextAdapted(gpa, func_ty_key, adapter, ctx);

    if (gop.found_existing) {
        ip.extra.items.len = prev_extra_len;
        return gop.key_ptr.*;
    }

    const new_index: Index = @enumFromInt(ip.items.len);
    ip.items.appendAssumeCapacity(.{
        .tag = .type_function,
        .data = func_type_extra_index,
    });

    gop.key_ptr.* = new_index;
    return new_index;
}

pub fn indexToKey(ip: *const InternPool, index: Index) Key {
    assert(index != .none);
    const tag = ip.items.items(.tag)[@intFromEnum(index)];
    const data = ip.items.items(.data)[@intFromEnum(index)];

    return switch (tag) {
        .simple_type => .{ .simple_type = @enumFromInt(@intFromEnum(index)) },
        .simple_value => .{ .simple_value = @enumFromInt(@intFromEnum(index)) },
        .int_comptime_int_u32 => .{ .int = .{
            .ty = .comptime_int_type,
            .storage = .{ .u64 = data },
        } },
        .int_comptime_int_i32 => .{ .int = .{
            .ty = .comptime_int_type,
            .storage = .{ .i64 = @as(i32, @bitCast(data)) },
        } },
        .int_i32 => .{ .int = .{
            .ty = .i32_type,
            .storage = .{ .i64 = @as(i32, @bitCast(data)) },
        } },
        .int_u32 => .{ .int = .{
            .ty = .u32_type,
            .storage = .{ .u64 = data },
        } },
        .int_positive => ip.indexToKeyBigInt(data, true),
        .int_negative => ip.indexToKeyBigInt(data, false),
        .float_f64 => .{ .float = .{
            .ty = .f64_type,
            .storage = .{ .f64 = extraData(ip, Float64, data).get() },
        } },
        .float_comptime_float => .{ .float = .{
            .ty = .comptime_float_type,
            .storage = .{ .f64 = extraData(ip, Float64, data).get() },
        } },

        .string => .{ .string = @enumFromInt(data) },

        .@"extern" => .{ .@"extern" = extraData(ip, Key.Extern, data) },

        .type_function => .{ .func_type = extraFuncType(ip, data) },
    };
}

fn indexToKeyBigInt(ip: *const InternPool, limb_index: u32, positive: bool) Key {
    const int: Int = @bitCast(ip.limbs.items[limb_index..][0..Int.limbs_items_len].*);
    const big_int: BigIntConst = .{
        .limbs = ip.limbs.items[limb_index + Int.limbs_items_len ..][0..int.limbs_len],
        .positive = positive,
    };
    return .{ .int = .{
        .ty = int.ty,
        .storage = if (big_int.toInt(u64)) |x|
            .{ .u64 = x }
        else |_| if (big_int.toInt(i64)) |x|
            .{ .i64 = x }
        else |_|
            .{ .big_int = big_int },
    } };
}

/// includes .comptime_int_type
pub fn isIntegerType(ip: *const InternPool, ty: Index) bool {
    _ = ip;
    return switch (ty) {
        .comptime_int_type,
        .u64_type,
        .u32_type,
        .i64_type,
        .i32_type,
        => true,
        else => false,
    };
}

fn addInt(
    ip: *InternPool,
    gpa: Allocator,
    ty: Index,
    tag: Tag,
    limbs: []const Limb,
) !void {
    const limbs_len: u32 = @intCast(limbs.len);
    try ip.limbs.ensureUnusedCapacity(gpa, Int.limbs_items_len + limbs_len);
    ip.items.appendAssumeCapacity(.{
        .tag = tag,
        .data = @intCast(ip.limbs.items.len),
    });
    ip.limbs.addManyAsArrayAssumeCapacity(Int.limbs_items_len).* = @bitCast(Int{
        .ty = ty,
        .limbs_len = limbs_len,
    });
    ip.limbs.appendSliceAssumeCapacity(limbs);
}

fn addExtra(ip: *InternPool, gpa: Allocator, item: anytype) Allocator.Error!u32 {
    const field_count = @typeInfo(@TypeOf(item)).@"struct".fields.len;
    try ip.extra.ensureUnusedCapacity(gpa, field_count);
    return addExtraAssumeCapacity(ip, item);
}

fn addExtraAssumeCapacity(ip: *InternPool, item: anytype) u32 {
    const result: u32 = @intCast(ip.extra.items.len);
    const info = @typeInfo(@TypeOf(item)).@"struct";
    inline for (info.fields) |field| {
        ip.extra.appendAssumeCapacity(switch (field.type) {
            Index,
            NullTerminatedString,
            OptionalNullTerminatedString,
            => @intFromEnum(@field(item, field.name)),

            u32,
            i32,
            => @bitCast(@field(item, field.name)),

            else => @compileError("bad field type: " ++ @typeName(field.type)),
        });
    }
    return result;
}

fn extraDataTrail(ip: *const InternPool, comptime T: type, index: u32) struct { data: T, end: u32 } {
    var result: T = undefined;
    const fields = @typeInfo(T).@"struct".fields;
    inline for (fields, index..) |field, extra_index| {
        const extra_item = ip.extra.items[extra_index];
        @field(result, field.name) = switch (field.type) {
            Index,
            NullTerminatedString,
            OptionalNullTerminatedString,
            => @enumFromInt(extra_item),

            u32,
            i32,
            => @bitCast(extra_item),

            else => @compileError("bad field type: " ++ @typeName(field.type)),
        };
    }
    return .{
        .data = result,
        .end = @intCast(index + fields.len),
    };
}

fn extraData(ip: *const InternPool, comptime T: type, index: u32) T {
    return extraDataTrail(ip, T, index).data;
}

fn extraFuncType(ip: *const InternPool, extra_index: u32) Key.FuncType {
    const type_function = extraDataTrail(ip, Tag.TypeFunction, extra_index);
    return .{
        .param_types = .{
            .start = type_function.end,
            .len = type_function.data.params_len,
        },
        .return_type = type_function.data.return_type,
    };
}

/// Trailing: Limb for every limbs_len
pub const Int = packed struct {
    ty: Index,
    limbs_len: u32,

    const limbs_items_len = @divExact(@sizeOf(Int), @sizeOf(Limb));
};

/// A f64 value, broken up into 2 u32 parts.
pub const Float64 = struct {
    piece0: u32,
    piece1: u32,

    pub fn get(self: Float64) f64 {
        const int_bits = @as(u64, self.piece0) | (@as(u64, self.piece1) << 32);
        return @bitCast(int_bits);
    }

    fn pack(val: f64) Float64 {
        const bits: u64 = @bitCast(val);
        return .{
            .piece0 = @truncate(bits),
            .piece1 = @truncate(bits >> 32),
        };
    }
};

pub fn typeOf(ip: *const InternPool, index: Index) Index {

    // This optimization of static keys is required so that typeOf can be called
    // on static keys that haven't been added yet during static key initialization.
    // An alternative would be to topological sort the static keys, but this would
    // mean that the range of type indices would not be dense.

    return switch (index) {
        .comptime_int_type,
        .comptime_float_type,
        .f64_type,
        .u32_type,
        .i32_type,
        .u64_type,
        .i64_type,
        .string_type,
        .void_type,
        .type_type,
        => .type_type,

        .zero, .one, .negative_one => .comptime_int_type,
        .void_value => .void_type,

        // This optimization on tags is needed so that indexToKey can call
        // typeOf without being recursive.
        _ => {
            const item = ip.items.get(@intFromEnum(index));
            return switch (item.tag) {
                .simple_type => unreachable, // handled via Index above

                .type_function,
                => .type_type,

                .string => .string_type,

                .int_u32 => .u32_type,
                .int_i32 => .i32_type,

                .float_f64 => .f64_type,

                .int_comptime_int_u32,
                .int_comptime_int_i32,
                => .comptime_int_type,

                .float_comptime_float => .comptime_float_type,

                // Note these are stored in limbs data, not extra data.
                .int_positive,
                .int_negative,
                => {
                    const int: Int = @bitCast(ip.limbs.items[item.data..][0..Int.limbs_items_len].*);
                    return int.ty;
                },

                .@"extern" => extraData(ip, Key.Extern, item.data).ty,

                // values, not types
                .simple_value,
                => unreachable,
            };
        },
        .none => unreachable,
    };
}

pub fn funcTypeReturnType(ip: *const InternPool, ty: Index) Index {
    const item = ip.items.get(@intFromEnum(ty));
    assert(item.tag == .type_function);
    return extraData(ip, Tag.TypeFunction, item.data).return_type;
}

pub fn indexToFuncType(ip: *const InternPool, val: Index) ?Key.FuncType {
    const item = ip.items.get(@intFromEnum(val));
    switch (item.tag) {
        .type_function => return extraFuncType(ip, item.data),
        else => return null,
    }
}

pub fn deinit(
    ip: *InternPool,
    gpa: Allocator,
) void {
    ip.items.deinit(gpa);
    ip.map.deinit(gpa);
    ip.string_bytes.deinit(gpa);
    ip.strings.deinit(gpa);
    ip.string_map.deinit(gpa);
    ip.extra.deinit(gpa);
    ip.limbs.deinit(gpa);
}

/// Stored-side context. The map holds `Index`es; we need the ip to
/// decode them back to Keys for hashing/comparison.
const Context = struct {
    ip: *const InternPool,

    pub fn hash(ctx: @This(), index: Index) u64 {
        return ctx.ip.indexToKey(index).hash64(ctx.ip);
    }
    pub fn eql(ctx: @This(), a: Index, b: Index) bool {
        return ctx.ip.indexToKey(a).eql(ctx.ip.indexToKey(b), ctx.ip);
    }
};

/// Probe-side adapter. Lets us look up a stored `Index` using a `Key`.
const Adapter = struct {
    ip: *const InternPool,

    pub fn hash(adpt: @This(), key: Key) u64 {
        return key.hash64(adpt.ip);
    }
    pub fn eql(adpt: @This(), key: Key, stored: Index) bool {
        return key.eql(adpt.ip.indexToKey(stored), adpt.ip);
    }
};

/// This is equivalent to `Key.FuncType` but adjusted to have a slice for `param_types`.
pub const GetFuncTypeKey = struct {
    param_types: []const Index,
    return_type: Index,
};

/// How many items in the InternPool are statically known.
/// This is specified with an integer literal and a corresponding comptime
/// assert below to break an unfortunate and arguably incorrect dependency loop
/// when compiling.
pub const static_len = Dir.Inst.Ref.static_len;

pub const Tag = enum(u8) {
    /// A type that can be represented with only an enum tag.
    simple_type,

    /// Type: u32
    /// data is integer value
    int_u32,
    /// Type: i32
    /// data is integer value bitcasted to u32.
    int_i32,
    /// A comptime_int that fits in a u32.
    /// data is integer value.
    int_comptime_int_u32,
    /// A comptime_int that fits in an i32.
    /// data is integer value bitcasted to u32.
    int_comptime_int_i32,
    /// A positive integer value.
    /// data is a limbs index to `Int`.
    int_positive,
    /// A negative integer value.
    /// data is a limbs index to `Int`.
    int_negative,
    /// An f64 value.
    /// data is extra index to Float64.
    float_f64,
    /// A comptime_float value.
    /// data is extra index to Float64.
    float_comptime_float,
    /// A string
    /// data is NullTerminatedString
    string,

    /// A value that can be represented with only an enum tag.
    simple_value,
    /// A function body type.
    /// `data` is extra index to `TypeFunction`.
    type_function,
    /// An extern function (a host import).
    /// `data` is extra index to `Key.Extern`.
    @"extern",

    pub const TypeFunction = struct {
        params_len: u32,
        return_type: Index,
    };
};

// Order must match `Index`'s static members exactly (dense, 0-based):
// static_keys[i] is asserted at `init` to intern at Index `i`.
pub const static_keys: [static_len]Key = .{
    .{ .simple_type = .u32 },
    .{ .simple_type = .i32 },
    .{ .simple_type = .u64 },
    .{ .simple_type = .i64 },
    .{ .simple_type = .f64 },
    .{ .simple_type = .comptime_int },
    .{ .simple_type = .comptime_float },
    .{ .simple_type = .string },
    .{ .simple_type = .void },
    .{ .simple_type = .type },

    .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .u64 = 0 },
    } },
    .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .u64 = 1 },
    } },
    .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .i64 = -1 },
    } },
    .{ .simple_value = .void },
};

test "InternPool same key returns same index" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try ip.get(gpa, .{ .simple_type = .comptime_int });
    const b = try ip.get(gpa, .{ .simple_type = .comptime_int });
    try std.testing.expect(a == b);
}

test "InternPool same key returns not the same index" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try ip.get(gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .u64 = 42 } } });
    const b = try ip.get(gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .u64 = 42 } } });
    const c = try ip.get(gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .u64 = 43 } } });
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
}

test "InternPool getString dedups identical bytes" {
    const gpa = std.testing.allocator;
    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try ip.getString(gpa, "foo");
    const b = try ip.getString(gpa, "foo");
    const c = try ip.getString(gpa, "bar");
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
    try std.testing.expectEqualStrings("foo", a.toSlice(&ip));
    try std.testing.expectEqualStrings("bar", c.toSlice(&ip));
}

test "InternPool getFuncType dedups" {
    const gpa = std.testing.allocator;
    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try ip.getFuncType(gpa, .{ .param_types = &.{.f64_type}, .return_type = .f64_type });
    const b = try ip.getFuncType(gpa, .{ .param_types = &.{.f64_type}, .return_type = .f64_type });
    // Differs from `a` only in a param type, so it must not dedup.
    const c = try ip.getFuncType(gpa, .{ .param_types = &.{.string_type}, .return_type = .f64_type });
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
}

test "InternPool extern dedups" {
    const gpa = std.testing.allocator;
    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const ty = try ip.getFuncType(gpa, .{ .param_types = &.{.f64_type}, .return_type = .f64_type });
    const print = try ip.getString(gpa, "print");
    const puts = try ip.getString(gpa, "puts");

    const a = try ip.get(gpa, .{ .@"extern" = .{ .name = print, .ty = ty, .lib_name = .none } });
    const b = try ip.get(gpa, .{ .@"extern" = .{ .name = print, .ty = ty, .lib_name = .none } });
    // Differs from `a` only in the name, so it must not dedup.
    const c = try ip.get(gpa, .{ .@"extern" = .{ .name = puts, .ty = ty, .lib_name = .none } });
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
}

test "InternPool dedups string values" {
    const gpa = std.testing.allocator;
    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try ip.get(gpa, .{ .string = try ip.getString(gpa, "foo") });
    const b = try ip.get(gpa, .{ .string = try ip.getString(gpa, "foo") });
    const c = try ip.get(gpa, .{ .string = try ip.getString(gpa, "bar") });
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
    try std.testing.expectEqualStrings("foo", ip.indexToKey(a).string.toSlice(&ip));
}

test "InternPool dedups the same value across storage variants" {
    const gpa = std.testing.allocator;
    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const via_u64 = try ip.get(gpa, .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .u64 = 42 },
    } });

    var limbs = [_]Limb{42};
    const via_big = try ip.get(gpa, .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .big_int = .{ .limbs = &limbs, .positive = true } },
    } });

    try std.testing.expect(via_u64 == via_big);
}

test "InternPool dedups big integers" {
    const gpa = std.testing.allocator;
    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    // 2^100: limb0 = 0, limb1 = 2^36 (on 64-bit limbs)
    var limbs = [_]Limb{ 0, 1 << 36 };
    const key: Key = .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .big_int = .{ .limbs = &limbs, .positive = true } },
    } };

    const a = try ip.get(gpa, key);
    const b = try ip.get(gpa, key);
    try std.testing.expect(a == b);
}

test "InternPool get leaves no phantom map entry when an allocation fails" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    // A comptime_float is interned by writing a `Float64` into `extra`.
    const key: Key = .{ .float = .{
        .ty = .comptime_float_type,
        .storage = .{ .f64 = 3.5 },
    } };

    var failing_state: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ip.get(failing_state.allocator(), key));

    // Every entry in the map must name a real item, and there must be exactly one entry per item.
    var it = ip.map.keyIterator();
    while (it.next()) |interned| {
        try std.testing.expect(@intFromEnum(interned.*) < ip.items.len);
    }
    try std.testing.expectEqual(ip.items.len, @as(usize, ip.map.count()));

    // The pool is still usable.
    const index = try ip.get(gpa, key);
    try std.testing.expectEqual(@as(f64, 3.5), ip.indexToKey(index).float.storage.f64);
}

test "InternPool Context.eql compares big integers by value, not by limb identity" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    // A Duni integer literal too large for u64 is stored as limbs, so its `Key`
    // holds a slice into `ip.limbs`. Two occurrences of the same literal hold
    // equal digits at different offsets, so comparing the slices themselves
    // instead of the digits they point at reports equal values as different.
    // The two items are placed with `addInt` because `get` dedups through
    // `Adapter`, which never lets a second copy reach `Context`.
    var limbs = [_]Limb{ 0, 1 << 36 }; // 2^100
    try ip.items.ensureUnusedCapacity(gpa, 2);
    try addInt(&ip, gpa, .comptime_int_type, .int_positive, &limbs);
    const first: Index = @enumFromInt(ip.items.len - 1);
    try addInt(&ip, gpa, .comptime_int_type, .int_positive, &limbs);
    const second: Index = @enumFromInt(ip.items.len - 1);

    const ctx: Context = .{ .ip = &ip };
    try std.testing.expect(ctx.eql(first, second));
}

test "InternPool void value is a value of type void" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    try std.testing.expectEqual(SimpleValue.void, ip.indexToKey(.void_value).simple_value);
    try std.testing.expectEqual(Index.void_type, ip.typeOf(.void_value));
}
