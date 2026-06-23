const std = @import("std");

const Sema = @import("../Sema.zig");
const InternPool = @import("../InternPool.zig");

const Value = @import("../Value.zig");

/// Add two integers. The result is interned in its most compact form; a true
/// 64-bit overflow is a compile error rather than a wrap.
pub fn comptimeIntAdd(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const sum = std.math.add(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    const result_ip = try ip.get(sema.gpa, .{ .number = .{ .storage = .{ .int = sum } } });
    return Value.fromInterned(result_ip);
}

/// Subtract two integers. Negative results are fine; 64-bit overflow is an error.
pub fn comptimeIntSub(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const difference = std.math.sub(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    const result_ip = try ip.get(sema.gpa, .{ .number = .{ .storage = .{ .int = difference } } });
    return Value.fromInterned(result_ip);
}

/// Multiply two integers. 64-bit overflow is an error.
pub fn comptimeIntMul(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const product = std.math.mul(i64, lhs.toSignedInt(ip), rhs.toSignedInt(ip)) catch return error.AnalysisFail;
    const result_ip = try ip.get(sema.gpa, .{ .number = .{ .storage = .{ .int = product } } });
    return Value.fromInterned(result_ip);
}

/// Divide two `number`s. `/` always yields a float (Python/JS semantics): both
/// operands are lifted to `f64`. Division by zero is a compile error.
pub fn numberDiv(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    const divisor = rhs.toFloat(ip);
    if (divisor == 0) {
        std.debug.print("error: division by zero\n", .{});
        return error.AnalysisFail;
    }
    const quotient = lhs.toFloat(ip) / divisor;
    const result_ip = try ip.get(sema.gpa, .{ .number = .{ .storage = .{ .float = quotient } } });
    return Value.fromInterned(result_ip);
}
