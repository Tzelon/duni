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

const Dir = @import("Dir.zig");

const Air = @import("Sema/Air.zig");

const InternPool = @import("InternPool.zig");

gpa: Allocator,

// AIR instructions
instructions: std.MultiArrayList(Air.Inst) = .{},

/// Maps ZIR to AIR.
// inst_map is how Sema remembers, for every DIR instruction it has already lowered, the AIR ref (or interned comptime value) to substitute when later DIR instructions reference it.
inst_map: InstMap = .{},

code: Dir,

pub fn analyze(gpa: Allocator, code: Dir, ip: *InternPool) !Air {
    var sema = Sema{ .gpa = gpa, .code = code };
    defer sema.deinit();

    try sema.instructions.ensureTotalCapacity(gpa, code.instructions.len);
    const body = code.bodySlice(code.main_body_start, code.main_body_len);
    try sema.inst_map.ensureSpaceForInstructions(sema.gpa, body);

    const tags = sema.code.instructions.items(.tag);

    for (body) |inst_idx| {
        const i = @intFromEnum(inst_idx);
        const air_ref = switch (tags[i]) {
            .int => try sema.dirInt(ip, inst_idx),
            .add => try sema.dirArithmetic(ip, inst_idx),
            else => unreachable,
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
    // TODO: we shouldn't @intCast here, need to handle big int properly.
    assert(int <= std.math.maxInt(u32)); // protect TODO
    const ip_index = try ip.get(sema.gpa, .{ .number = @intCast(int) });
    return Air.Inst.Ref.fromInterned(ip_index);
}

fn dirArithmetic(
    sema: *Sema,
    ip: *InternPool,
    inst: Dir.Inst.Index,
) CompileError!Air.Inst.Ref {
    const inst_data = sema.code.instructions.items(.data)[@intFromEnum(inst)].pl_node;
    const extra = sema.code.extraData(Dir.Inst.Bin, inst_data.payload_index).data;
    const lhs = sema.resolveInst(extra.lhs);
    const rhs = sema.resolveInst(extra.rhs);

    return sema.analyzeArithmetic(ip, lhs, rhs);
}

fn analyzeArithmetic(sema: *Sema, ip: *InternPool, lhs: Air.Inst.Ref, rhs: Air.Inst.Ref) CompileError!Air.Inst.Ref {
    //TODO: we assume everything is comptime know and we can fold. this will not be true in the future
    const lhs_ip = lhs.toInterned().?;
    const rhs_ip = rhs.toInterned().?;

    const lhs_n = ip.indexToKey(lhs_ip).number;
    const rhs_n = ip.indexToKey(rhs_ip).number;

    const sum = std.math.add(u32, lhs_n, rhs_n) catch return error.AnalysisFail;

    const result_ip = try ip.get(sema.gpa, .{ .number = sum });
    const result_ref = Air.Inst.Ref.fromInterned(result_ip);

    return result_ref;
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

test "analyze int literal" {
    const gpa = std.testing.allocator;

    var insts: std.MultiArrayList(Dir.Inst) = .{};
    try insts.append(gpa, .{ .tag = .int, .data = .{ .int = 42 } });

    const extra = try gpa.alloc(u32, 1);
    extra[0] = 0; // body[0] = instruction index 0

    var dir = Dir{
        .instructions = insts.toOwnedSlice(),
        .extra = extra,
        .main_body_start = 0,
        .main_body_len = 1,
    };
    defer dir.deinit(gpa);

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    var air = try Sema.analyze(gpa, dir, &ip);
    defer air.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), air.instructions.len);

    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    try std.testing.expectEqual(Air.Inst.Tag.ret, tags[0]);

    const ip_index = datas[0].un_op.toInterned().?;
    try std.testing.expectEqual(InternPool.Key{ .number = 42 }, ip.indexToKey(ip_index));
}

test "analyze 1 + 2" {
    const gpa = std.testing.allocator;

    // Dir layout for `1 + 2`:
    //   %0 = int(1)
    //   %1 = int(2)
    //   %2 = add  pl_node{ payload_index = 0 }
    //
    // extra:
    //   [0] = Bin.lhs = ref(%0)
    //   [1] = Bin.rhs = ref(%1)
    //   [2..5] = body indices [0, 1, 2]
    var insts: std.MultiArrayList(Dir.Inst) = .{};
    try insts.append(gpa, .{ .tag = .int, .data = .{ .int = 1 } });
    try insts.append(gpa, .{ .tag = .int, .data = .{ .int = 2 } });
    try insts.append(gpa, .{
        .tag = .add,
        .data = .{ .pl_node = .{
            .src_node = @enumFromInt(0),
            .payload_index = 0,
        } },
    });

    const idx_0: Dir.Inst.Index = @enumFromInt(0);
    const idx_1: Dir.Inst.Index = @enumFromInt(1);

    const extra = try gpa.alloc(u32, 5);
    extra[0] = @intFromEnum(idx_0.toRef()); // Bin.lhs = %0
    extra[1] = @intFromEnum(idx_1.toRef()); // Bin.rhs = %1
    extra[2] = 0; // body[0] = %0
    extra[3] = 1; // body[1] = %1
    extra[4] = 2; // body[2] = %2

    var dir = Dir{
        .instructions = insts.toOwnedSlice(),
        .extra = extra,
        .main_body_start = 2,
        .main_body_len = 3,
    };
    defer dir.deinit(gpa);

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    var air = try Sema.analyze(gpa, dir, &ip);
    defer air.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 1), air.instructions.len);

    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    try std.testing.expectEqual(Air.Inst.Tag.ret, tags[0]);

    const ip_index = datas[0].un_op.toInterned().?;
    try std.testing.expectEqual(InternPool.Key{ .number = 3 }, ip.indexToKey(ip_index));
}
