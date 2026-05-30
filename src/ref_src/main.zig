const std = @import("std");
// const AstGen = @import("AstGen.zig");
const Ast = @import("ast.zig");
const AstPrinter = @import("ast_printer.zig");
const Io = std.Io;
const process = std.process;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len == 1) {
        try repl(io, gpa);
    } else if (args.len == 2) {
        try runFile(io, gpa, args[1]);
    } else {
        std.debug.print("Usage: duni [path]\n", .{});
        process.exit(64);
    }
}

fn repl(io: std.Io, _: Allocator) !void {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const reader = &stdin_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    while (true) {
        stdout.print("> ", .{}) catch std.debug.panic("cannot write to stdout", .{});

        while (reader.takeDelimiterExclusive('\n')) |line| {
            std.debug.print("{s}", .{line});
            // _ = try interpret(line);
        } else |err| switch (err) {
            error.EndOfStream, // stream ended not on a line break
            error.StreamTooLong, // line could not fit in buffer
            error.ReadFailed, // caller can check reader implementation for diagnostics
            => |e| return e,
        }
    }
}

fn runFile(io: std.Io, allocator: Allocator, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, std.Io.Limit.unlimited, std.mem.Alignment.of(u8), 0);
    defer allocator.free(source);

    std.debug.print("source \n {s} :source \n", .{source});
    var tree = try Ast.parse(allocator, source);
    defer tree.deinit(allocator);
    // try AstGen.generate(allocator, tree);

    std.debug.print("AST:\n", .{});
    AstPrinter.print(&tree);

    for (tree.errors) |err| {
        std.debug.print("Error: {any}", .{err.tag});
    }
}

test "simple test" {}
