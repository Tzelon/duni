//! Built with Claude — do not use in prod.
//! Emits WebAssembly text format (.wat) from Sema's AIR.
//! Stepping stone before a binary emitter.

const WatGen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("Sema/Air.zig");
const InternPool = @import("InternPool.zig");

gpa: Allocator,
air: *const Air,
ip: *const InternPool,
out: *std.Io.Writer,
indent: u32 = 0,

pub fn emit(gpa: Allocator, air: *const Air, ip: *const InternPool, out: *std.Io.Writer) !void {
    var gen = WatGen{ .gpa = gpa, .air = air, .ip = ip, .out = out };

    try out.writeAll("(module\n");
    gen.indent = 1;
    try gen.writeFunc();
    try gen.writeIndent();
    try out.writeAll("(export \"main\" (func $main))\n");
    try out.writeAll(")\n");
}

fn writeFunc(gen: *WatGen) !void {
    try gen.writeIndent();
    try gen.out.print("(func $main (result {s})\n", .{gen.resultType()});
    gen.indent += 1;
    try gen.writeBody();
    gen.indent -= 1;
    try gen.writeIndent();
    try gen.out.writeAll(")\n");
}

/// The wasm type of `main`'s result, derived from the value the final `ret`
/// returns. Placeholder until Duni's `number` gets a defined runtime lowering.
fn resultType(gen: *const WatGen) []const u8 {
    const datas = gen.air.instructions.items(.data);
    const ret_ref = datas[gen.air.instructions.len - 1].un_op;
    const ip_index = ret_ref.toInterned() orelse @panic("inst-index refs not supported yet");
    return switch (gen.ip.indexToKey(ip_index)) {
        .int => "i32",
        .float => "f64",
        .simple_type => @panic("type as value not supported yet"),
    };
}

fn writeBody(gen: *WatGen) !void {
    const tags = gen.air.instructions.items(.tag);
    const datas = gen.air.instructions.items(.data);
    for (tags, datas) |tag, data| try gen.writeInst(tag, data);
}

fn writeInst(gen: *WatGen, tag: Air.Inst.Tag, data: Air.Inst.Data) !void {
    switch (tag) {
        .ret => {
            try gen.writeRef(data.un_op);
            try gen.writeIndent();
            try gen.out.writeAll("return\n");
        },
    }
}

fn writeRef(gen: *WatGen, ref: Air.Inst.Ref) !void {
    const ip_index = ref.toInterned() orelse @panic("inst-index refs not supported yet");
    switch (gen.ip.indexToKey(ip_index)) {
        .int => |int| {
            // The function result is i32 for now, so that is the runtime
            // boundary: comptime ints of any width are fine as long as the
            // final value fits. A `.big_int` here never fits — decode
            // narrowing only leaves limbs for values beyond u64/i64.
            const value = switch (int.storage) {
                inline .u64, .i64 => |x| std.math.cast(i32, x) orelse
                    @panic("TODO: integer result does not fit in i32"),
                .big_int => @panic("TODO: integer result does not fit in i32"),
            };
            try gen.writeIndent();
            try gen.out.print("i32.const {d}\n", .{value});
        },
        .float => |float| {
            try gen.writeIndent();
            try gen.out.print("f64.const {d}\n", .{float.storage.f64});
        },
        .simple_type => @panic("type as value not supported yet"),
    }
}

fn writeIndent(gen: *WatGen) !void {
    for (0..gen.indent) |_| try gen.out.writeAll("  ");
}

fn expectWat(value: InternPool.Key, expected: []const u8) !void {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);
    const ip_index = try ip.get(gpa, value);

    var insts: std.MultiArrayList(Air.Inst) = .{};
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = .fromInterned(ip_index) } });
    var air = Air{ .instructions = insts.toOwnedSlice() };
    defer air.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &air, &ip, &w);
    try std.testing.expectEqualStrings(expected, w.buffer[0..w.end]);
}

test "emit int result" {
    try expectWat(.{ .int = .{ .ty = .comptime_int_type, .storage = .{ .i64 = -42 } } },
        \\(module
        \\  (func $main (result i32)
        \\    i32.const -42
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    );
}

test "emit float result" {
    try expectWat(.{ .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = 2.5 } } },
        \\(module
        \\  (func $main (result f64)
        \\    f64.const 2.5
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    );
}
