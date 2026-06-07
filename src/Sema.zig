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

//TODO(tzelon): for now this is here, but it should be in the upper layer that orchestrait the compilation
pub const CompileError = error{
    OutOfMemory,
    /// The compilation update is no longer desired.
    Canceled,
    /// When this is returned, the compile error for the failure has already been recorded.
    AnalysisFail,
    /// In a comptime scope, a return instruction was encountered. This error is only seen when
    /// doing a comptime function call.
    ComptimeReturn,
    /// In a comptime scope, a break instruction was encountered. This error is only seen when
    /// evaluating a comptime block.
    ComptimeBreak,
};

/// Alias to `zcu.gpa`.
gpa: Allocator,
/// Points to the temporary arena allocator of the Sema.
/// This arena will be cleared when the sema is destroyed.
// arena: Allocator,
code: Dir,

pub fn analyze(gpa: Allocator, code: Dir) !void {
    var sema = Sema{ .gpa = gpa, .code = code };

    // sema.code.i

    sema.analyzeBody(null, null) catch |err| switch (err) {
        error.ComptimeBreak => unreachable, // unexpected comptime control flow
        else => |e| return e,
    };
}

pub fn analyzeBody(sema: *Sema, block: anytype, body: anytype) !void {
    _ = body;
    const tags = sema.code.instructions.items(.tag);
    const datas = sema.code.instructions.items(.data);

    for (tags, datas) |tag, data| switch (tag) {
        .int => _ = try ip.get(gpa, io, .{ .number = .{ .ty = .number_type, .storage = .{ .u64 = data.int } } }),
        .float => _ = try ip.get(gpa, io, .{ .number = .{ .ty = .number_type, .storage = .{ .f64 = data.float } } }),
    };

    // We use a while (true) loop here to avoid a redundant way of breaking out of
    // the loop. The only way to break out of the loop is with a `noreturn`
    // instruction.
    // var i: u32 = 0;
    // while (true) {
    //     const inst = body[i];
    //
    //     const air_ref: Air.Inst.Ref = inst: switch (tags[@intFromEnum(inst)]) {
    //         .int => try sema.dirInt(block, inst),
    //     };
    // }
}

fn dirInt(sema: *Sema, block: anytype, inst: Dir.Inst.Index) CompileError!Air.Inst.Ref {
    _ = block;

    const int = sema.code.instructions.items(.data)[@intFromEnum(inst)].int;
    return sema.pt.intRef(.comptime_number, int);
}
