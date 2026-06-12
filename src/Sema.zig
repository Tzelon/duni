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

const InternPool = @import("Sema/InternPool.zig");

gpa: Allocator,

instructions: std.MultiArrayList(Air.Inst) = .{},

code: Dir,

pub fn analyze(gpa: Allocator, code: Dir, ip: *InternPool) !Air {
    var sema = Sema{ .gpa = gpa, .code = code };
    defer sema.deinit();

    try sema.instructions.ensureTotalCapacity(gpa, code.instructions.len);

    const tags = sema.code.instructions.items(.tag);
    const datas = sema.code.instructions.items(.data);

    for (tags, datas) |tag, data| switch (tag) {
        .int => {
            const ip_index = try ip.get(gpa, .{ .number = @intCast(data.int) });
            const ref = Air.Inst.Ref.fromInterned(ip_index);
            try sema.instructions.append(gpa, .{
                .tag = .ret,
                .data = .{ .un_op = ref },
            });
        },
        // else => unreachable,
    };

    return .{ .instructions = sema.instructions.toOwnedSlice() };
}

pub fn deinit(sema: *Sema) void {
    sema.instructions.deinit(sema.gpa);
    sema.* = undefined;
}

test "analyze int literal" {
    const gpa = std.testing.allocator;

    var insts: std.MultiArrayList(Dir.Inst) = .{};
    try insts.append(gpa, .{ .tag = .int, .data = .{ .int = 42 } });
    var dir = Dir{ .instructions = insts.toOwnedSlice() };
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
