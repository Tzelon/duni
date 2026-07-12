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
    try gen.out.writeAll("(func $main (result i32)\n");
    gen.indent += 1;
    try gen.writeBody();
    gen.indent -= 1;
    try gen.writeIndent();
    try gen.out.writeAll(")\n");
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
        .float => @panic("TODO: float lowering awaits the number->wasm type decision"),
        .simple_type => @panic("type as value not supported yet"),
    }
}

fn writeIndent(gen: *WatGen) !void {
    for (0..gen.indent) |_| try gen.out.writeAll("  ");
}
