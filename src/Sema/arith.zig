const std = @import("std");
const assert = std.debug.assert;
const BigIntConst = std.math.big.int.Const;
const BigIntMutable = std.math.big.int.Mutable;

const Sema = @import("../Sema.zig");
const InternPool = @import("../InternPool.zig");

const Value = @import("../Value.zig");

// Int

/// Add two integers, returning a `comptime_int` regardless of the input types.
pub fn comptimeIntAdd(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space, ip);
    const rhs_bigint = rhs.toBigInt(&rhs_space, ip);
    const limbs = try sema.arena.alloc(
        std.math.big.Limb,
        @max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
    );
    var result_bigint: BigIntMutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.add(lhs_bigint, rhs_bigint);

    const result_ip = try ip.get(sema.gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .big_int = result_bigint.toConst() } } });
    return Value.fromInterned(result_ip);
}

/// Subtract two integers, returning a `comptime_int` regardless of the input types.
pub fn comptimeIntSub(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space, ip);
    const rhs_bigint = rhs.toBigInt(&rhs_space, ip);
    const limbs = try sema.arena.alloc(
        std.math.big.Limb,
        @max(lhs_bigint.limbs.len, rhs_bigint.limbs.len) + 1,
    );
    var result_bigint: BigIntMutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    result_bigint.sub(lhs_bigint, rhs_bigint);

    const result_ip = try ip.get(sema.gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .big_int = result_bigint.toConst() } } });
    return Value.fromInterned(result_ip);
}

/// Multiply two integers, returning a `comptime_int` regardless of the input types.
pub fn comptimeIntMul(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    // TODO is this a performance issue? maybe we should try the operation without
    // resorting to BigInt first.
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space, ip);
    const rhs_bigint = rhs.toBigInt(&rhs_space, ip);
    const limbs = try sema.arena.alloc(
        std.math.big.Limb,
        lhs_bigint.limbs.len + rhs_bigint.limbs.len,
    );
    var result_bigint: BigIntMutable = .{ .limbs = limbs, .positive = undefined, .len = undefined };
    const limbs_buffer = try sema.arena.alloc(
        std.math.big.Limb,
        std.math.big.int.calcMulLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len, 1),
    );
    result_bigint.mul(lhs_bigint, rhs_bigint, limbs_buffer, sema.arena);

    const result_ip = try ip.get(sema.gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .big_int = result_bigint.toConst() } } });
    return Value.fromInterned(result_ip);
}

pub fn intDivTrunc(sema: *Sema, ip: *InternPool, lhs: Value, rhs: Value) !Value {
    var lhs_space: Value.BigIntSpace = undefined;
    var rhs_space: Value.BigIntSpace = undefined;
    const lhs_bigint = lhs.toBigInt(&lhs_space, ip);
    const rhs_bigint = rhs.toBigInt(&rhs_space, ip);
    const limbs_q = try sema.arena.alloc(std.math.big.Limb, lhs_bigint.limbs.len);
    const limbs_r = try sema.arena.alloc(std.math.big.Limb, rhs_bigint.limbs.len);
    const limbs_buf = try sema.arena.alloc(
        std.math.big.Limb,
        std.math.big.int.calcDivLimbsBufferLen(lhs_bigint.limbs.len, rhs_bigint.limbs.len),
    );
    var result_q: BigIntMutable = .{ .limbs = limbs_q, .positive = undefined, .len = undefined };
    var result_r: BigIntMutable = .{ .limbs = limbs_r, .positive = undefined, .len = undefined };
    result_q.divTrunc(&result_r, lhs_bigint, rhs_bigint, limbs_buf);

    // TODO(tzelon): for none comptime_int_type
    // if (ty.toIntern() != .comptime_int_type) {
    //     const info = ty.intInfo(zcu);
    //     if (!result_q.toConst().fitsInTwosComp(info.signedness, info.bits)) {
    //         return error.Overflow;
    //     }
    // }

    const result_ip = try ip.get(sema.gpa, .{ .int = .{ .ty = .comptime_int_type, .storage = .{ .big_int = result_q.toConst() } } });
    return Value.fromInterned(result_ip);
}

// Float

/// Negate a float by flipping its sign. Must not lower to `0 - x`:
/// IEEE says `0.0 - (-0.0) == +0.0`, which would lose negative zero.
pub fn floatNeg(sema: *Sema, ip: *InternPool, val: Value) !Value {
    const result_ip = try ip.get(sema.gpa, .{ .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = -val.toFloat(f64, ip) } } });
    return Value.fromInterned(result_ip);
}
