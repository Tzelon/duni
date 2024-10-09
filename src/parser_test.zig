const std = @import("std");
const Parser = @import("./parser.zig").Parser;
const Error = @import("./parser.zig").Error.Tag;
const mem = std.mem;
const print = std.debug.print;
const io = std.io;
const maxInt = std.math.maxInt;

test "explode: missing expresion" {
    try testExplode(
        \\ 4 +
    , error.ParseError);
}

test "explode: missing l_paren" {
    try testExplode(
        \\ (4 
        \\   + 
        \\  2
    , error.ParseError);
}

// TODO: we should test here recoverable errors
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

fn testExplode(source: [:0]const u8, expected_error: anyerror) !void {
    var parser = try Parser.init(source, std.testing.allocator);
    try std.testing.expectError(expected_error, parser.parse());
    try printErrors(&parser);

    defer parser.deinit();
}

fn printErrors(parser: *Parser) !void {
    const stderr = io.getStdErr().writer();
    const errors = try parser.errors.toOwnedSlice(std.testing.allocator);
    defer std.testing.allocator.free(errors);

    for (errors) |parse_error| {
        const loc = parser.tokenLocation(0, parse_error.token);
        try stderr.print("(memory buffer):{d}:{d}: error: ", .{ loc.line + 1, loc.column + 1 });
        try parser.renderError(parse_error, stderr);
        try stderr.print("\n{s}\n", .{parser.source[loc.line_start..loc.line_end]});
        {
            var i: usize = 0;
            while (i < loc.column) : (i += 1) {
                try stderr.writeAll(" ");
            }
            try stderr.writeAll("^");
        }
        try stderr.writeAll("\n");
    }
}
