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
    sema.deinit();

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
    };

    return .{ .instructions = sema.instructions.toOwnedSlice() };
}

pub fn deinit(sema: *Sema) void {
    sema.instructions.deinit(sema.gpa);
    sema.* = undefined;
}
