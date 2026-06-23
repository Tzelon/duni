//! End-to-end tests for the whole pipeline: source text -> WAT. These exercise
//! the compact `number` representation (i32 / i64 / f64) and the error paths for
//! values that don't fit.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Sema = @import("Sema.zig");
const InternPool = @import("InternPool.zig");
const WatGen = @import("WatGen.zig");

/// Compile a Duni source string to WAT, writing into `buf` and returning the
/// written slice. Returns the pipeline's error on any failed stage.
fn emitWat(gpa: Allocator, source: [:0]const u8, buf: []u8) ![]const u8 {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    var dir = try AstGen.generate(gpa, tree);
    defer dir.deinit(gpa);

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    var air = try Sema.analyze(gpa, dir, &ip);
    defer air.deinit(gpa);

    var writer = std.Io.Writer.fixed(buf);
    try WatGen.emit(gpa, &air, &ip, &writer);
    return writer.buffered();
}

fn expectWatContains(source: [:0]const u8, needle: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const wat = try emitWat(std.testing.allocator, source, &buf);
    std.testing.expect(std.mem.indexOf(u8, wat, needle) != null) catch |err| {
        std.debug.print("WAT was:\n{s}\nexpected to contain: {s}\n", .{ wat, needle });
        return err;
    };
}

test "small integer result emits i32" {
    try expectWatContains("5", "(result i32)");
    try expectWatContains("5", "i32.const 5");
}

test "result beyond i32 emits i64" {
    // 3_000_000_000 itself exceeds i32, and the sum exceeds it further.
    try expectWatContains("3000000000 + 3000000000", "(result i64)");
    try expectWatContains("3000000000 + 3000000000", "i64.const 6000000000");
}

test "subtraction can go negative" {
    try expectWatContains("10 - 25", "i32.const -15");
}

test "division always yields a float" {
    try expectWatContains("5 / 2", "(result f64)");
    try expectWatContains("5 / 2", "f64.const 2.5");
}

test "op.duni expression divides to a float" {
    // (100 - 10 * 3) / 10 == 70 / 10 == 7.0
    try expectWatContains("(100 - 10 * 3) / 10", "(result f64)");
    try expectWatContains("(100 - 10 * 3) / 10", "f64.const 7");
}

test "integer overflow is a compile error, not a panic" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectError(
        error.AnalysisFail,
        emitWat(std.testing.allocator, "9223372036854775807 + 1", &buf),
    );
}

test "literal beyond 64-bit is a compile error" {
    var buf: [1024]u8 = undefined;
    // 2^63 fits u64 but not i64.
    try std.testing.expectError(
        error.AnalysisFail,
        emitWat(std.testing.allocator, "9223372036854775808", &buf),
    );
    // Far beyond u64 -> caught earlier as a big_int literal.
    try std.testing.expectError(
        error.AnalysisFail,
        emitWat(std.testing.allocator, "999999999999999999999999999", &buf),
    );
}

test "division by zero is a compile error" {
    var buf: [1024]u8 = undefined;
    try std.testing.expectError(
        error.AnalysisFail,
        emitWat(std.testing.allocator, "5 / 0", &buf),
    );
}
