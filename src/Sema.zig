//! Semantic analysis of ZIR instructions.
//! Shared to every Block. Stored on the stack.
//! State used for compiling a ZIR into AIR.
//! Transforms untyped ZIR instructions into semantically-analyzed AIR instructions.
//! Does type checking, comptime control flow, and safety-check generation.
//! This is the the heart of the Zig compiler.

const Sema = @This();

const std = @import("std");
const math = std.math;
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.sema);

const arith = @import("Sema/arith.zig");

const Dir = @import("Dir.zig");

const Value = @import("Value.zig");

const Air = @import("Sema/Air.zig");

const InternPool = @import("InternPool.zig");

const String = @import("string.zig");

gpa: Allocator,

// AIR instructions
instructions: std.MultiArrayList(Air.Inst) = .{},

/// Maps ZIR to AIR.
// inst_map is how Sema remembers, for every DIR instruction it has already lowered, the AIR ref (or interned comptime value) to substitute when later DIR instructions reference it.
inst_map: InstMap = .{},

/// Points to the temporary arena allocator of the Sema.
/// This arena will be cleared when the sema is destroyed.
arena: Allocator,

code: Dir,

pub fn analyze(gpa: Allocator, code: Dir, ip: *InternPool) !Air {
    var analysis_arena: std.heap.ArenaAllocator = .init(gpa);
    defer analysis_arena.deinit();
    var sema = Sema{ .gpa = gpa, .code = code, .arena = analysis_arena.allocator() };
    defer sema.deinit();

    try sema.instructions.ensureTotalCapacity(gpa, code.instructions.len);
    const body = code.bodySlice(code.main_body_start, code.main_body_len);
    try sema.inst_map.ensureSpaceForInstructions(sema.gpa, body);

    const tags = sema.code.instructions.items(.tag);

    for (body) |inst_idx| {
        const i = @intFromEnum(inst_idx);
        const air_ref = switch (tags[i]) {
            .int => try sema.dirInt(ip, inst_idx),
            .int_big => try sema.dirIntBig(ip, inst_idx),
            .float => try sema.dirFloat(ip, inst_idx),
            .add => try sema.dirArithmetic(ip, .add, inst_idx),
            .sub => try sema.dirArithmetic(ip, .sub, inst_idx),
            .mul => try sema.dirArithmetic(ip, .mul, inst_idx),
            .negate => try sema.dirNegate(ip, inst_idx),
            .div => try sema.dirArithmetic(ip, .div, inst_idx),
            .str => try sema.dirStr(ip, inst_idx),
            .decl_val => unreachable,
        };

        sema.inst_map.putAssumeCapacity(inst_idx, air_ref);
    }

    const last_indx = body[body.len - 1];
    const last_ref = sema.inst_map.get(last_indx).?;

    try sema.instructions.append(gpa, .{
        .tag = .ret,
        .data = .{ .un_op = last_ref },
    });

    return .{ .instructions = sema.instructions.toOwnedSlice() };
}

fn dirInt(sema: *Sema, ip: *InternPool, inst: Dir.Inst.Index) CompileError!Air.Inst.Ref {
    const int = sema.code.instructions.items(.data)[@intFromEnum(inst)].int;
    const ip_index = try ip.get(sema.gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .u64 = int } } });
    return Air.Inst.Ref.fromInterned(ip_index);
}

fn dirIntBig(sema: *Sema, ip: *InternPool, inst: Dir.Inst.Index) CompileError!Air.Inst.Ref {
    const int = sema.code.instructions.items(.data)[@intFromEnum(inst)].str;
    const byte_count = int.len * @sizeOf(std.math.big.Limb);
    const limb_bytes = sema.code.string_bytes[@intFromEnum(int.start)..][0..byte_count];

    // TODO: this allocation and copy is only needed because the limbs may be unaligned.
    // If DIR is adjusted so that big int limbs are guaranteed to be aligned, these
    // two lines can be removed.
    const limbs = try sema.arena.alloc(std.math.big.Limb, int.len);
    @memcpy(mem.sliceAsBytes(limbs), limb_bytes);

    const ip_index = try ip.get(sema.gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .big_int = .{ .limbs = limbs, .positive = true } } } });
    return Air.Inst.Ref.fromInterned(ip_index);
}

fn dirFloat(sema: *Sema, ip: *InternPool, inst: Dir.Inst.Index) CompileError!Air.Inst.Ref {
    const float = sema.code.instructions.items(.data)[@intFromEnum(inst)].float;
    const ip_index = try ip.get(sema.gpa, .{ .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = float } } });
    return Air.Inst.Ref.fromInterned(ip_index);
}

fn dirArithmetic(
    sema: *Sema,
    ip: *InternPool,
    dir_tag: Dir.Inst.Tag,
    inst: Dir.Inst.Index,
) CompileError!Air.Inst.Ref {
    const inst_data = sema.code.instructions.items(.data)[@intFromEnum(inst)].pl_node;
    const extra = sema.code.extraData(Dir.Inst.Bin, inst_data.payload_index).data;
    const lhs = sema.resolveInst(extra.lhs);
    const rhs = sema.resolveInst(extra.rhs);

    return sema.analyzeArithmetic(ip, dir_tag, lhs, rhs);
}

fn analyzeArithmetic(sema: *Sema, ip: *InternPool, dir_tag: Dir.Inst.Tag, lhs: Air.Inst.Ref, rhs: Air.Inst.Ref) CompileError!Air.Inst.Ref {

    //TODO: we assume everything is comptime know and we can fold. this will not be true in the future
    const maybe_lhs_val = sema.resolveValue(lhs);
    const maybe_rhs_val = sema.resolveValue(rhs);

    if (maybe_lhs_val) |lhs_val| {
        if (maybe_rhs_val) |rhs_val| {
            const lhs_is_float = ip.indexToKey(lhs_val.toIntern()) == .float;
            const rhs_is_float = ip.indexToKey(rhs_val.toIntern()) == .float;
            const is_int = !lhs_is_float and !rhs_is_float;

            const result_val = switch (dir_tag) {
                .add => try arith.add(sema, ip, lhs_val, rhs_val, is_int),
                .sub => try arith.sub(sema, ip, lhs_val, rhs_val, is_int),
                .mul => try arith.mul(sema, ip, lhs_val, rhs_val, is_int),
                .div => blk: {
                    // Division by zero is a comptime error for ints and floats alike —
                    // IEEE inf/nan are never produced by comptime folding.
                    if (rhs_val.isZero(ip)) return error.AnalysisFail;
                    break :blk try arith.div(sema, ip, lhs_val, rhs_val);
                },
                else => unreachable,
            };
            return Air.internedToRef(result_val.toIntern());
        }
    }

    //TODO: We only support comptime known values
    unreachable;
}

fn dirStr(sema: *Sema, ip: *InternPool, inst: Dir.Inst.Index) CompileError!Air.Inst.Ref {
    const bytes = sema.code.instructions.items(.data)[@intFromEnum(inst)].str.get(&sema.code);
    return sema.addStrLit(ip, try ip.getString(sema.gpa, bytes));
}

fn dirNegate(sema: *Sema, ip: *InternPool, inst: Dir.Inst.Index) CompileError!Air.Inst.Ref {
    const inst_data = sema.code.instructions.items(.data)[@intFromEnum(inst)].un_node;
    const rhs = sema.resolveInst(inst_data.operand);

    // Floats negate by sign-flip, not `0 - x` — preserves -0.0.
    if (sema.resolveValue(rhs)) |rhs_val| {
        if (ip.indexToKey(rhs_val.toIntern()) == .float) {
            return .fromValue(try arith.floatNeg(sema, ip, rhs_val));
        }
    }

    // negate is `0 - operand`
    const lhs = Air.internedToRef(.zero);
    return sema.analyzeArithmetic(ip, .sub, lhs, rhs);
}

fn addStrLit(sema: *Sema, ip: *InternPool, string: String.NullTerminatedString) CompileError!Air.Inst.Ref {
    const val = try ip.get(sema.gpa, .{ .string = string });
    return .fromInterned(val);
}

fn resolveInst(sema: *Sema, dir_ref: Dir.Inst.Ref) Air.Inst.Ref {
    assert(dir_ref != .none);
    if (dir_ref.toIndex()) |i| {
        return sema.inst_map.get(i).?;
    }
    // First section of indexes correspond to a set number of constant values.
    // We intentionally map the same indexes to the same values between DIR and AIR.
    return @enumFromInt(@intFromEnum(dir_ref));
}

/// Return the Value corresponding to a given AIR ref, or `null` if it refers to a runtime value.
fn resolveValue(sema: *Sema, inst: Air.Inst.Ref) ?Value {
    _ = sema;
    assert(inst != .none);

    if (inst.toInterned()) |ip_index| {
        return .fromInterned(ip_index);
    }

    return null;
}

pub fn deinit(sema: *Sema) void {
    sema.instructions.deinit(sema.gpa);
    sema.inst_map.deinit(sema.gpa);
    sema.* = undefined;
}

/// Stores the mapping from `Dir.Inst.Index -> Air.Inst.Ref`, which is used by sema to resolve
/// instructions during analysis.
/// Instead of a hash table approach, InstMap is simply a slice that is indexed into using the
/// dir instruction index and a start offset. An index is not present in the map if the value
/// at the index is `Air.Inst.Ref.none`.
/// `ensureSpaceForInstructions` can be called to force InstMap to have a mapped range that
/// includes all instructions in a slice. After calling this function, `putAssumeCapacity*` can
/// be called safely for any of the instructions passed in.
pub const InstMap = struct {
    items: []Air.Inst.Ref = &[_]Air.Inst.Ref{},
    start: Dir.Inst.Index = @enumFromInt(0),

    pub fn deinit(map: InstMap, allocator: mem.Allocator) void {
        allocator.free(map.items);
    }

    pub fn get(map: InstMap, key: Dir.Inst.Index) ?Air.Inst.Ref {
        if (!map.contains(key)) return null;
        return map.items[@intFromEnum(key) - @intFromEnum(map.start)];
    }

    /// writes the ref, period. If the slot already had a value, it's silently overwritten.
    pub fn putAssumeCapacity(
        map: *InstMap,
        key: Dir.Inst.Index,
        ref: Air.Inst.Ref,
    ) void {
        map.items[@intFromEnum(key) - @intFromEnum(map.start)] = ref;
    }

    /// asserts the slot is .none first, then writes. Panics on a double-write.
    pub fn putAssumeCapacityNoClobber(
        map: *InstMap,
        key: Dir.Inst.Index,
        ref: Air.Inst.Ref,
    ) void {
        assert(!map.contains(key));
        map.putAssumeCapacity(key, ref);
    }

    pub const GetOrPutResult = struct {
        value_ptr: *Air.Inst.Ref,
        found_existing: bool,
    };

    pub fn getOrPutAssumeCapacity(
        map: *InstMap,
        key: Dir.Inst.Index,
    ) GetOrPutResult {
        const index = @intFromEnum(key) - @intFromEnum(map.start);
        return GetOrPutResult{
            .value_ptr = &map.items[index],
            .found_existing = map.items[index] != .none,
        };
    }

    pub fn remove(map: InstMap, key: Dir.Inst.Index) bool {
        if (!map.contains(key)) return false;
        map.items[@intFromEnum(key) - @intFromEnum(map.start)] = .none;
        return true;
    }

    pub fn contains(map: InstMap, key: Dir.Inst.Index) bool {
        return map.items[@intFromEnum(key) - @intFromEnum(map.start)] != .none;
    }

    pub fn ensureSpaceForInstructions(
        map: *InstMap,
        allocator: mem.Allocator,
        insts: []const Dir.Inst.Index,
    ) !void {
        const start, const end = mem.minMax(u32, @ptrCast(insts));
        const map_start = @intFromEnum(map.start);
        if (map_start <= start and end < map.items.len + map_start)
            return;

        const old_start = if (map.items.len == 0) start else map_start;
        var better_capacity = map.items.len;
        var better_start = old_start;
        while (true) {
            const extra_capacity = better_capacity / 2 + 16;
            better_capacity += extra_capacity;
            better_start -|= @intCast(extra_capacity / 2);
            if (better_start <= start and end < better_capacity + better_start)
                break;
        }

        const start_diff = old_start - better_start;
        const new_items = try allocator.alloc(Air.Inst.Ref, better_capacity);
        @memset(new_items[0..start_diff], .none);
        @memcpy(new_items[start_diff..][0..map.items.len], map.items);
        @memset(new_items[start_diff + map.items.len ..], .none);

        allocator.free(map.items);
        map.items = new_items;
        map.start = @enumFromInt(better_start);
    }
};

pub const CompileError = error{
    OutOfMemory,
    /// When this is returned, the compile error for the failure has already been recorded.
    AnalysisFail,
};

// Test helpers

/// Build a `Dir` from hand-written instructions. `bin_extra` holds the callers'
/// `Bin` payloads; the body (every instruction, in order) is appended after it,
/// mirroring AstGen.generate's main-body layout.
fn buildTestDir(
    gpa: Allocator,
    insts: []const Dir.Inst,
    bin_extra: []const u32,
    string_bytes: []const u8,
) !Dir {
    var list: std.MultiArrayList(Dir.Inst) = .{};
    errdefer list.deinit(gpa);
    for (insts) |inst| try list.append(gpa, inst);

    const extra = try gpa.alloc(u32, bin_extra.len + insts.len);
    errdefer gpa.free(extra);
    @memcpy(extra[0..bin_extra.len], bin_extra);
    for (0..insts.len) |i| extra[bin_extra.len + i] = @intCast(i);

    return .{
        .instructions = list.toOwnedSlice(),
        .extra = extra,
        .string_bytes = try gpa.dupe(u8, string_bytes),
        .main_body_start = @intCast(bin_extra.len),
        .main_body_len = @intCast(insts.len),
    };
}

/// Analyze a hand-built Dir and expect the returned value to intern to
/// `expected`. Comparing indexes (not keys) is exact for every value kind:
/// big-int keys hold slices and 0.0/-0.0 compare equal as floats, but the
/// pool guarantees one index per canonical value.
fn expectAnalyzed(
    insts: []const Dir.Inst,
    bin_extra: []const u32,
    string_bytes: []const u8,
    expected: InternPool.Key,
) !void {
    const gpa = std.testing.allocator;

    var dir = try buildTestDir(gpa, insts, bin_extra, string_bytes);
    defer dir.deinit(gpa);

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    var air = try Sema.analyze(gpa, dir, &ip);
    defer air.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), air.instructions.len);
    try std.testing.expectEqual(Air.Inst.Tag.ret, air.instructions.items(.tag)[0]);

    const actual = air.instructions.items(.data)[0].un_op.toInterned().?;
    try std.testing.expectEqual(try ip.get(gpa, expected), actual);
}

fn instRef(i: u32) Dir.Inst.Ref {
    return @as(Dir.Inst.Index, @enumFromInt(i)).toRef();
}

test "analyze int literal" {
    try expectAnalyzed(&.{
        .{ .tag = .int, .data = .{ .int = 42 } },
    }, &.{}, &.{}, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .u64 = 42 } } });
}

test "analyze big int literal" {
    const limbs = [_]std.math.big.Limb{ 0, 1 }; // 2^64
    try expectAnalyzed(&.{
        .{ .tag = .int_big, .data = .{ .str = .{ .start = @enumFromInt(0), .len = limbs.len } } },
    }, &.{}, mem.sliceAsBytes(&limbs), .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .big_int = .{ .limbs = &limbs, .positive = true } },
    } });
}

test "analyze float literal" {
    try expectAnalyzed(&.{
        .{ .tag = .float, .data = .{ .float = 3.14 } },
    }, &.{}, &.{}, .{ .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = 3.14 } } });
}

test "analyze string literal" {
    const gpa = std.testing.allocator;

    var dir = try buildTestDir(gpa, &.{
        .{ .tag = .str, .data = .{ .str = .{ .start = @enumFromInt(0), .len = 5 } } },
    }, &.{}, "hello");
    defer dir.deinit(gpa);

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    var air = try Sema.analyze(gpa, dir, &ip);
    defer air.deinit(gpa);

    const actual = air.instructions.items(.data)[0].un_op.toInterned().?;
    try std.testing.expectEqualStrings("hello", ip.indexToKey(actual).string.toSlice(&ip));
}

test "analyze subtraction with negative result" {
    try expectAnalyzed(&.{
        .{ .tag = .int, .data = .{ .int = 1 } },
        .{ .tag = .int, .data = .{ .int = 2 } },
        .{ .tag = .sub, .data = .{ .pl_node = .{ .src_node = @enumFromInt(0), .payload_index = 0 } } },
    }, &.{ @intFromEnum(instRef(0)), @intFromEnum(instRef(1)) }, &.{}, .{ .int = .{
        .ty = .comptime_int_type,
        .storage = .{ .i64 = -1 },
    } });
}

test "analyze division" {
    // `/` is always IEEE division on f64 (`number` = f64); int operands
    // coerce to float, and an evenly-dividing int pair still yields a float —
    // the result type never depends on the operand values.
    try expectAnalyzed(&.{
        .{ .tag = .int, .data = .{ .int = 7 } },
        .{ .tag = .int, .data = .{ .int = 2 } },
        .{ .tag = .div, .data = .{ .pl_node = .{ .src_node = @enumFromInt(0), .payload_index = 0 } } },
    }, &.{ @intFromEnum(instRef(0)), @intFromEnum(instRef(1)) }, &.{}, .{
        .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = 3.5 } },
    });
    try expectAnalyzed(&.{
        .{ .tag = .int, .data = .{ .int = 4 } },
        .{ .tag = .int, .data = .{ .int = 2 } },
        .{ .tag = .div, .data = .{ .pl_node = .{ .src_node = @enumFromInt(0), .payload_index = 0 } } },
    }, &.{ @intFromEnum(instRef(0)), @intFromEnum(instRef(1)) }, &.{}, .{
        .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = 2.0 } },
    });
}

test "analyze negate int" {
    try expectAnalyzed(&.{
        .{ .tag = .int, .data = .{ .int = 5 } },
        .{ .tag = .negate, .data = .{ .un_node = .{ .src_node = @enumFromInt(0), .operand = instRef(0) } } },
    }, &.{}, &.{}, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .i64 = -5 } } });
}

test "analyze negate preserves negative zero" {
    // Sharp because we compare indexes: if negation produced +0.0, interning
    // the expected -0.0 would create a distinct index and the test fails.
    try expectAnalyzed(&.{
        .{ .tag = .float, .data = .{ .float = 0.0 } },
        .{ .tag = .negate, .data = .{ .un_node = .{ .src_node = @enumFromInt(0), .operand = instRef(0) } } },
    }, &.{}, &.{}, .{ .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = -0.0 } } });
}

test "analyze 1 / 0 fails analysis" {
    const gpa = std.testing.allocator;

    var dir = try buildTestDir(gpa, &.{
        .{ .tag = .int, .data = .{ .int = 1 } },
        .{ .tag = .int, .data = .{ .int = 0 } },
        .{ .tag = .div, .data = .{ .pl_node = .{ .src_node = @enumFromInt(0), .payload_index = 0 } } },
    }, &.{ @intFromEnum(instRef(0)), @intFromEnum(instRef(1)) }, &.{});
    defer dir.deinit(gpa);

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    try std.testing.expectError(error.AnalysisFail, Sema.analyze(gpa, dir, &ip));
}

test "analyze float division by zero fails analysis" {
    const gpa = std.testing.allocator;

    // Both zero signs must be caught — 0.0 and -0.0 intern as distinct values.
    for ([_]f64{ 0.0, -0.0 }) |divisor| {
        var dir = try buildTestDir(gpa, &.{
            .{ .tag = .float, .data = .{ .float = 1.5 } },
            .{ .tag = .float, .data = .{ .float = divisor } },
            .{ .tag = .div, .data = .{ .pl_node = .{ .src_node = @enumFromInt(0), .payload_index = 0 } } },
        }, &.{ @intFromEnum(instRef(0)), @intFromEnum(instRef(1)) }, &.{});
        defer dir.deinit(gpa);

        var ip: InternPool = .{};
        try ip.init(gpa);
        defer ip.deinit(gpa);

        try std.testing.expectError(error.AnalysisFail, Sema.analyze(gpa, dir, &ip));
    }
}
