const std = @import("std");
const AstGen = @import("AstGen.zig");
const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const InternPool = @import("InternPool.zig");
const Compliation = @import("Compilation.zig");
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
        runFile(io, gpa, args[1]) catch |err| switch (err) {
            // Diagnostics were already rendered, so exit quietly.
            error.CompileErrorsReported => process.exit(1),
            else => |e| return e,
        };
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

fn runFile(io: std.Io, gpa: Allocator, source_path: []const u8) !void {
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    //load root file

    const path = try Compliation.Path.fromUnresolved(gpa, &.{source_path});
    const new_file = try gpa.create(Compliation.File);

    new_file.* = .{
        .status = .never_loaded,
        .path = path,
        .source = null,
        .tree = null,
        .dir = null,
    };

    const comp = try arena.create(Compliation);
    comp.* = .{
        .file = new_file,
        .gpa = gpa,
        .io = io,
    };
    try comp.init(gpa, io);
    defer comp.deinit();

    try comp.compile();

    var errors = try comp.getAllErrorsAlloc();
    defer errors.deinit(comp.gpa);

    if (errors.errorMessageCount() > 0) {
        const color: std.zig.Color = .auto;
        errors.renderToStderr(comp.io, .{}, color) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return error.PrintingErrorsFailed,
        };
        return error.CompileErrorsReported;
    }

    // var air = try Sema.analyze(allocator, dir, &ip);
    // defer air.deinit(allocator);
}
