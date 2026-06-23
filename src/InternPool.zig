const InternPool = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Hash = std.hash.Wyhash;

const Dir = @import("Dir.zig");

const string = @import("string.zig");
const NullTerminatedString = string.NullTerminatedString;

// List of all constant items
items: std.MultiArrayList(Item) = .empty,
// A map to check if an item is already exists
map: std.hash_map.HashMapUnmanaged(Index, void, Context, std.hash_map.default_max_load_percentage) = .empty,

// parameter names, struct field names, enum tag names
extra: std.ArrayList(u32) = .empty,

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
    number_type,

    /// Used by Air/Sema only.
    none = std.math.maxInt(u32),
    _,
};

pub const Key = union(enum) {
    simple_type: SimpleType,
    number: Number,

    /// Having `SimpleType` and `SimpleValue` in separate enums makes it easier to
    /// implement logic that only wants to deal with types because the logic can
    /// ignore all simple values. Note that technically, types are values.
    pub const SimpleType = enum(u32) {
        comptime_number = @intFromEnum(Index.number_type),
    };

    /// A comptime-known `number`. The intern pool stores it in the most compact
    /// form that fits (see `Tag`), but the decoded key is always normalized:
    /// integers as `i64`, floats as `f64`. This normalization is what makes the
    /// dedup round-trip (`get` then `indexToKey`) stable.
    pub const Number = struct {
        storage: Storage,

        pub const Storage = union(enum) {
            int: i64,
            float: f64,
        };
    };

    pub fn hash64(key: Key, ip: *const InternPool) u64 {
        _ = ip;
        const asBytes = std.mem.asBytes;
        const KeyTag = @typeInfo(Key).@"union".tag_type.?;
        const seed = @intFromEnum(@as(KeyTag, key));

        return switch (key) {
            .simple_type => |x| Hash.hash(seed, asBytes(&x)),
            .number => |n| switch (n.storage) {
                .int => |v| Hash.hash(seed, asBytes(&v)),
                .float => |v| Hash.hash(seed, asBytes(&v)),
            },
        };
    }
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
    if (gop.found_existing) return gop.key_ptr.*;

    switch (key) {
        .simple_type => |simple_type| {
            assert(@intFromEnum(simple_type) == ip.items.len);
            ip.items.appendAssumeCapacity(.{
                .tag = .simple_type,
                .data = 0, // avoid writing `undefined` bits to a file
            });
        },
        .number => |number| switch (number.storage) {
            .int => |value| if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
                // Fits inline: bitcast the i32 into the item's `data` word.
                ip.items.appendAssumeCapacity(.{
                    .tag = .number_i32,
                    .data = @bitCast(@as(i32, @intCast(value))),
                });
            } else {
                const extra_index = try ip.addExtraU64(gpa, @bitCast(value));
                ip.items.appendAssumeCapacity(.{ .tag = .number_i64, .data = extra_index });
            },
            .float => |value| {
                const extra_index = try ip.addExtraU64(gpa, @bitCast(value));
                ip.items.appendAssumeCapacity(.{ .tag = .number_f64, .data = extra_index });
            },
        },
    }

    gop.key_ptr.* = new_index;
    return new_index;
}

/// Append a 64-bit payload to `extra` as two `u32` words (low, high) and return
/// the index of the first word. Used to spill numbers wider than `Item.data`.
fn addExtraU64(ip: *InternPool, gpa: Allocator, bits: u64) Allocator.Error!u32 {
    const extra_index: u32 = @intCast(ip.extra.items.len);
    try ip.extra.appendSlice(gpa, &.{ @truncate(bits), @truncate(bits >> 32) });
    return extra_index;
}

/// Read back a 64-bit payload previously stored by `addExtraU64`.
fn getExtraU64(ip: *const InternPool, extra_index: u32) u64 {
    const low: u64 = ip.extra.items[extra_index];
    const high: u64 = ip.extra.items[extra_index + 1];
    return low | (high << 32);
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

pub fn indexToKey(ip: *const InternPool, index: Index) Key {
    assert(index != .none);
    const tag = ip.items.items(.tag)[@intFromEnum(index)];
    const data = ip.items.items(.data)[@intFromEnum(index)];

    return switch (tag) {
        .simple_type => .{ .simple_type = @enumFromInt(@intFromEnum(index)) },
        .number_i32 => .{ .number = .{ .storage = .{ .int = @as(i32, @bitCast(data)) } } },
        .number_i64 => .{ .number = .{ .storage = .{ .int = @bitCast(ip.getExtraU64(data)) } } },
        .number_f64 => .{ .number = .{ .storage = .{ .float = @bitCast(ip.getExtraU64(data)) } } },
    };
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

/// How many items in the InternPool are statically known.
/// This is specified with an integer literal and a corresponding comptime
/// assert below to break an unfortunate and arguably incorrect dependency loop
/// when compiling.
pub const static_len = Dir.Inst.Ref.static_len;

pub const Tag = enum(u8) {
    /// A type that can be represented with only an enum tag.
    simple_type,

    /// An integer that fits `i32`. `data` is the value, bitcast to `u32`.
    number_i32,
    /// An integer that needs `i64`. `data` indexes `extra` (two words: low, high).
    number_i64,
    /// A 64-bit float. `data` indexes `extra` (two words: low, high).
    number_f64,
};

pub const static_keys: [static_len]Key = .{.{ .simple_type = .comptime_number }};

test "InternPool same key returns same index" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try ip.get(gpa, .{ .simple_type = .comptime_number });
    const b = try ip.get(gpa, .{ .simple_type = .comptime_number });
    try std.testing.expect(a == b);
}

fn internInt(ip: *InternPool, gpa: Allocator, value: i64) !Index {
    return ip.get(gpa, .{ .number = .{ .storage = .{ .int = value } } });
}

fn internFloat(ip: *InternPool, gpa: Allocator, value: f64) !Index {
    return ip.get(gpa, .{ .number = .{ .storage = .{ .float = value } } });
}

test "InternPool same number returns same index, distinct values differ" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const a = try internInt(&ip, gpa, 42);
    const b = try internInt(&ip, gpa, 42);
    const c = try internInt(&ip, gpa, 43);
    try std.testing.expect(a == b);
    try std.testing.expect(a != c);
}

test "InternPool narrows by value and round-trips" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    // Fits i32 -> stored compactly as number_i32.
    const small = try internInt(&ip, gpa, 5);
    try std.testing.expectEqual(Tag.number_i32, ip.items.items(.tag)[@intFromEnum(small)]);
    try std.testing.expectEqual(@as(i64, 5), ip.indexToKey(small).number.storage.int);

    // Negative still fits i32.
    const negative = try internInt(&ip, gpa, -7);
    try std.testing.expectEqual(Tag.number_i32, ip.items.items(.tag)[@intFromEnum(negative)]);
    try std.testing.expectEqual(@as(i64, -7), ip.indexToKey(negative).number.storage.int);

    // Beyond i32 -> spills to number_i64.
    const big = try internInt(&ip, gpa, 5_000_000_000);
    try std.testing.expectEqual(Tag.number_i64, ip.items.items(.tag)[@intFromEnum(big)]);
    try std.testing.expectEqual(@as(i64, 5_000_000_000), ip.indexToKey(big).number.storage.int);

    // Float round-trips and dedups.
    const f = try internFloat(&ip, gpa, 2.5);
    const f2 = try internFloat(&ip, gpa, 2.5);
    try std.testing.expectEqual(Tag.number_f64, ip.items.items(.tag)[@intFromEnum(f)]);
    try std.testing.expect(f == f2);
    try std.testing.expectEqual(@as(f64, 2.5), ip.indexToKey(f).number.storage.float);
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
