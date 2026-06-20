const std = @import("std");
const assert = std.debug.assert;

const Sema = @import("../Sema.zig");
const InternPool = @import("../InternPool.zig");

const Value = @import("../Value.zig");

/// Add two integers, returning a `comptime_int` regardless of the input types.
pub fn comptimeIntAdd(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const sum = std.math.add(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    // TODO: result must fit in u32 until Key.number widens.
    assert(sum >= 0 and sum <= std.math.maxInt(u32));

    const result_ip = try ip.get(sema.gpa, .{ .number = @intCast(sum) });
    return Value.fromInterned(result_ip);
}

/// Subtract two integers, returning a `comptime_int` regardless of the input types.
pub fn comptimeIntSub(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const sum = std.math.sub(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    // TODO: result must fit in u32 until Key.number widens.
    assert(sum >= 0 and sum <= std.math.maxInt(u32));

    const result_ip = try ip.get(sema.gpa, .{ .number = @intCast(sum) });
    return Value.fromInterned(result_ip);
}

/// Multiply two integers, returning a `comptime_int` regardless of the input types.
pub fn comptimeIntMul(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const sum = std.math.mul(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    // TODO: result must fit in u32 until Key.number widens.
    assert(sum >= 0 and sum <= std.math.maxInt(u32));

    const result_ip = try ip.get(sema.gpa, .{ .number = @intCast(sum) });
    return Value.fromInterned(result_ip);
}

pub fn intDivTrunc(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const sum = std.math.divTrunc(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    // TODO: result must fit in u32 until Key.number widens.
    assert(sum >= 0 and sum <= std.math.maxInt(u32));

    const result_ip = try ip.get(sema.gpa, .{ .number = @intCast(sum) });
    return Value.fromInterned(result_ip);
}
