const std = @import("std");
const Parser = @import("./parser.zig").Parser;
const Error = @import("./parser.zig").Error.Tag;
const mem = std.mem;
const print = std.debug.print;
const io = std.io;
const maxInt = std.math.maxInt;

// TODO: we should test here recovery errors
test "recovery: non-associative operators" {
    // try testError(
    //     \\    4 +
    // , &[_]Error{
    //     .expected_expression,
    // });
}

var fixed_buffer_mem: [100 * 1024]u8 = undefined;

fn testError(source: [:0]const u8, expected_errors: []const Error) !void {
    var parser = try Parser.init(source, std.testing.allocator);
    try parser.parse();
    defer parser.deinit();
    const errors = try parser.errors.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(errors);

    std.testing.expectEqual(expected_errors.len, errors.len) catch |err| {
        std.debug.print("errors found: {any}\n", .{errors});
        return err;
    };
    for (expected_errors, 0..) |expected, i| {
        try std.testing.expectEqual(expected, errors[i].tag);
    }
}
