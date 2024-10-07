const std = @import("std");
const Parser = @import("./parser.zig").Parser;
const io = std.io;
const process = std.process;
const Allocator = std.mem.Allocator;

const errout = std.io.getStdErr().writer();
const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const args = try process.argsAlloc(allocator);
    defer {
        process.argsFree(allocator, args);
    }

    if (args.len == 1) {
        try repl(allocator);
    } else if (args.len == 2) {
        try runFile(allocator, args[1]);
    } else {
        std.debug.print("Usage: zlox [path]\n", .{});
        process.exit(64);
    }
}

fn repl(_: Allocator) !void {
    var buf = std.io.bufferedReader(stdin);
    var reader = buf.reader();

    var line_buff: [1024]u8 = undefined;

    while (true) {
        stdout.print("> ", .{}) catch std.debug.panic("cannot write to stdout", .{});
        const line = reader.readUntilDelimiterOrEof(&line_buff, '\n') catch {
            std.debug.panic("cannot read from stdin in repl", .{});
            break;
        } orelse {
            stdout.writeAll("\n") catch std.debug.panic("cannot write to stdout", .{});
            break;
        };
        std.debug.print("{s}", .{line});
        // _ = try interpret(line);
    }
}

fn runFile(allocator: Allocator, path: []const u8) !void {
    const source = try std.fs.cwd().readFileAllocOptions(allocator, path, std.math.maxInt(u32), null, @alignOf(u8), 0);
    defer allocator.free(source);

    std.debug.print("{s}", .{source});
    var parser = try Parser.init(source, allocator);
    try parser.parse();
    std.debug.print("tags {any} \n", .{parser.nodes.items(.tag)});
    std.debug.print("main_token {any} \n", .{parser.nodes.items(.main_token)});
    std.debug.print("data {any} \n", .{parser.nodes.items(.data)});
    // _ = try interpret(source);
}

test "simple test" {}
