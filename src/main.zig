const std = @import("std");
const AstGen = @import("AstGen.zig");
const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const InternPool = @import("InternPool.zig");
const WatGen = @import("WatGen.zig");
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

    var ip: InternPool = .{};
    try ip.init(allocator);
    defer ip.deinit(allocator);

    var tree = try Ast.parse(allocator, source);
    defer tree.deinit(allocator);

    var dir = try AstGen.generate(allocator, tree);
    defer dir.deinit(allocator);

    var air = try Sema.analyze(allocator, dir, &ip);
    defer air.deinit(allocator);

    for (tree.errors) |err| {
        std.debug.print("Error: {any}", .{err.tag});
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try WatGen.emit(allocator, &air, &ip, stdout);
    try stdout.flush();
}

// Whole-pipeline integration test (Text → Scanner → Parse → AstGen → Sema →
// WatGen), distinct from the per-stage unit tests. Guards the extern-call arc
// end to end: a call lowers to a wasm import + `call`.
test "pipeline: extern call lowers to a wasm import + call" {
    const gpa = std.testing.allocator;

    const source =
        \\extern fn print(x number) number
        \\
        \\print(43)
        \\
    ;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    var dir = try AstGen.generate(gpa, tree);
    defer dir.deinit(gpa);

    var air = try Sema.analyze(gpa, dir, &ip);
    defer air.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &air, &ip, &w);

    try std.testing.expectEqualStrings(
        \\(module
        \\  (import "host" "print" (func $print (param f64) (result f64)))
        \\  (func $main (result f64)
        \\    f64.const 43
        \\    call $print
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    , w.buffer[0..w.end]);
}
