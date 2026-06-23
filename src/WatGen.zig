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

/// The function's result type is the WASM type of the value it returns.
fn resultType(gen: *WatGen) []const u8 {
    const tags = gen.air.instructions.items(.tag);
    const datas = gen.air.instructions.items(.data);
    for (tags, datas) |tag, data| switch (tag) {
        .ret => return gen.wasmTypeOf(data.un_op),
    };
    @panic("function has no return");
}

/// Maps an interned `number` to its compact WASM type.
fn wasmTypeOf(gen: *WatGen, ref: Air.Inst.Ref) []const u8 {
    const ip_index = ref.toInterned() orelse @panic("inst-index refs not supported yet");
    return switch (gen.ip.indexToKey(ip_index)) {
        .number => |num| switch (num.storage) {
            .int => |value| if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) "i32" else "i64",
            .float => "f64",
        },
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
        .number => |num| {
            try gen.writeIndent();
            switch (num.storage) {
                .int => |value| try gen.out.print("{s}.const {d}\n", .{ gen.wasmTypeOf(ref), value }),
                .float => |value| try gen.out.print("f64.const {d}\n", .{value}),
            }
        },
        .simple_type => @panic("type as value not supported yet"),
    }
}

fn writeIndent(gen: *WatGen) !void {
    for (0..gen.indent) |_| try gen.out.writeAll("  ");
}
