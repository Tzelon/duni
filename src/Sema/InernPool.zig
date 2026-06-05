const InternPool = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Hash = std.hash.Wyhash;

// List of all constant items
items: std.MultiArrayList(Item) = .empty,
// A map to check if an item is already exists
map: std.hash_map.HashMapUnmanaged(Index, void, Context, std.hash_map.default_max_load_percentage) = .empty,

pub const Item = struct {
    tag: Tag,
    /// The doc comments on the respective Tag explain how to interpret this.
    data: u32,
};

/// Represents an index into `map`. It represents the canonical index
/// of a `Value` within this `InternPool`. The values are typed.
/// Two values which have the same type can be equality compared simply
/// by checking if their indexes are equal, provided they are both in
/// the same `InternPool`.
/// When adding a tag to this enum, consider adding a corresponding entry to
/// `primitives` in AstGen.zig.
pub const Index = enum(u32) {
    comptime_number_type,

    /// Used by Air/Sema only.
    none = std.math.maxInt(u32),
    _,
};

/// This data structure is used by the Zig language code generation and
/// therefore must be kept in sync with the compiler implementation.
pub const Signedness = enum(u1) {
    signed,
    unsigned,
};

pub const Key = union(enum) {
    simple_type: SimpleType,
    // number: Key.Number,

    /// Having `SimpleType` and `SimpleValue` in separate enums makes it easier to
    /// implement logic that only wants to deal with types because the logic can
    /// ignore all simple values. Note that technically, types are values.
    pub const SimpleType = enum(u32) {
        comptime_number = @intFromEnum(Index.comptime_number_type),
    };

    pub const Number = struct {
        ty: Index,
        storage: Storage,

        pub const Storage = union(enum) {
            u64: u64,
            i64: i64,
        };
    };

    pub fn hash64(key: Key, ip: *const InternPool) u64 {
        _ = ip;
        const asBytes = std.mem.asBytes;
        const KeyTag = @typeInfo(Key).@"union".tag_type.?;
        const seed = @intFromEnum(@as(KeyTag, key));

        return switch (key) {
            .simple_type => |x| Hash.hash(seed, asBytes(&x)),
        };
    }
};

pub fn get(ip: *InternPool, gpa: Allocator, io: Io, key: Key) Allocator.Error!Index {
    _ = io;
    const ctx: Context = .{ .ip = ip };
    const adapter: Adapter = .{ .ip = ip };

    const new_index: Index = @enumFromInt(ip.items.len);
    try ip.items.ensureUnusedCapacity(gpa, 1);
    const gop = try ip.map.getOrPutContextAdapted(gpa, key, adapter, ctx);
    if (gop.found_existing) return gop.key_ptr.*;

    switch (key) {
        .simple_type => |simple_type| {
            assert(@intFromEnum(simple_type) == ip.items.len);
            ip.items.appendAssumeCapacity(.{
                .tag = .simple_type,
                .data = 0, // avoid writing `undefined` bits to a file
            });
        },
        //TODO(tzelon): zig InternPool.zig line:7491
        // .number => |number| {
        //
        // }
    }

    gop.key_ptr.* = new_index;
    return new_index;
}

pub fn indexToKey(ip: *const InternPool, index: Index) Key {
    assert(index != .none);
    const tag = ip.items.items(.tag)[@intFromEnum(index)];
    _ = ip.items.items(.data)[@intFromEnum(index)];

    return switch (tag) {
        .simple_type => .{ .simple_type = @enumFromInt(@intFromEnum(index)) },
    };
}

pub fn deinit(ip: *InternPool, gpa: Allocator) void {
    ip.items.deinit(gpa);
    ip.map.deinit(gpa);
}

/// Stored-side context. The map holds `Index`es; we need the ip to
/// decode them back to Keys for hashing/comparison.
const Context = struct {
    ip: *const InternPool,

    pub fn hash(ctx: @This(), index: Index) u64 {
        return ctx.ip.indexToKey(index).hash64(ctx.ip);
    }
    pub fn eql(ctx: @This(), a: Index, b: Index) bool {
        return std.meta.eql(ctx.ip.indexToKey(a), ctx.ip.indexToKey(b));
    }
};

/// Probe-side adapter. Lets us look up a stored `Index` using a `Key`.
const Adapter = struct {
    ip: *const InternPool,

    pub fn hash(adpt: @This(), key: Key) u64 {
        return key.hash64(adpt.ip);
    }
    pub fn eql(adpt: @This(), key: Key, stored: Index) bool {
        return std.meta.eql(key, adpt.ip.indexToKey(stored));
    }
};

pub const Tag = enum(u8) {
    /// A type that can be represented with only an enum tag.
    simple_type,
};

test "same key returns same index" {
    const gpa = std.testing.allocator;
    var pl: InternPool = InternPool{};

    const a = try pl.get(gpa, std.testing.io, .{ .simple_type = .comptime_number });
    const b = try pl.get(gpa, std.testing.io, .{ .simple_type = .comptime_number });
    try std.testing.expectEqual(a, b);
    try std.testing.expectEqual(@as(usize, 1), pl.items.len);

    pl.deinit(gpa);
}
