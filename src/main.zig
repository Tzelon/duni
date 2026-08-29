const std = @import("std");
const AstGen = @import("AstGen.zig");
const Ast = @import("Ast.zig");
const Sema = @import("Sema.zig");
const InternPool = @import("InternPool.zig");
const WatGen = @import("WatGen.zig");
const Diagnostics = @import("Diagnostics.zig");
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
            error.CompileFailed => process.exit(1),
            else => process.exit(64),
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

fn runFile(io: std.Io, allocator: Allocator, path: []const u8) !void {
    const source = try std.Io.Dir.cwd().readFileAllocOptions(io, path, allocator, std.Io.Limit.unlimited, std.mem.Alignment.of(u8), 0);
    defer allocator.free(source);

    var ip: InternPool = .{};
    try ip.init(allocator);
    defer ip.deinit(allocator);

    var diags = Diagnostics{ .gpa = allocator };
    defer diags.deinit();

    var tree = try Ast.parse(allocator, source);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) {
        try diags.addParseErrors(&tree);
        return renderCompileErrors(io, &diags, &tree, path);
    }

    var dir = AstGen.generate(allocator, tree, &diags) catch |err| switch (err) {
        error.AnalysisFail => return renderCompileErrors(io, &diags, &tree, path),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer dir.deinit(allocator);

    var result = Sema.analyze(allocator, dir, &ip, &diags) catch |err| switch (err) {
        error.AnalysisFail => return renderCompileErrors(io, &diags, &tree, path),
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer result.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try WatGen.emit(allocator, &result, &ip, stdout);
    try stdout.flush();
}

/// Print every accumulated diagnostic to stderr and fail the compilation.
fn renderCompileErrors(io: std.Io, diags: *const Diagnostics, tree: *const Ast, path: []const u8) error{ CompileFailed, WriteFailed } {
    // Normalize the display path: a leading `./` says nothing.
    const display_path = if (std.mem.startsWith(u8, path, "./")) path[2..] else path;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    diags.render(tree, display_path, stderr) catch return error.WriteFailed;
    stderr.flush() catch return error.WriteFailed;
    return error.CompileFailed;
}
