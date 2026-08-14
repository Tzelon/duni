//! Built with Claude — do not use in prod.
//! Emits WebAssembly text format (.wat) from Sema's AIR.
//! Stepping stone before a binary emitter.

const WatGen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("Sema/Air.zig");
const InternPool = @import("InternPool.zig");
const NullTerminatedString = @import("string.zig").NullTerminatedString;

gpa: Allocator,
air: *const Air,
ip: *const InternPool,
out: *std.Io.Writer,
indent: u32 = 0,
/// String constants referenced by the body, mapped to their offset in linear
/// memory. Populated by `collectStrings` before anything is written.
string_offsets: std.AutoArrayHashMapUnmanaged(NullTerminatedString, u32) = .empty,

pub fn emit(gpa: Allocator, air: *const Air, ip: *const InternPool, out: *std.Io.Writer) !void {
    var gen = WatGen{ .gpa = gpa, .air = air, .ip = ip, .out = out };
    defer gen.string_offsets.deinit(gpa);

    try gen.collectStrings();

    try out.writeAll("(module\n");
    gen.indent = 1;
    try gen.writeDataSection();
    try gen.writeFunc();
    try gen.writeIndent();
    try out.writeAll("(export \"main\" (func $main))\n");
    try out.writeAll(")\n");
}

/// Assign every referenced string constant an offset in linear memory, in
/// order of first appearance, deduped by handle (equal strings share one
/// handle, so they share one data segment).
fn collectStrings(gen: *WatGen) !void {
    const tags = gen.air.instructions.items(.tag);
    const datas = gen.air.instructions.items(.data);
    var offset: u32 = 0;
    for (tags, datas) |tag, data| {
        const ref = switch (tag) {
            .ret => data.un_op,
        };
        const ip_index = ref.toInterned() orelse continue;
        switch (gen.ip.indexToKey(ip_index)) {
            .string => |handle| {
                const gop = try gen.string_offsets.getOrPut(gen.gpa, handle);
                if (!gop.found_existing) {
                    gop.value_ptr.* = offset;
                    offset += handle.length(gen.ip);
                }
            },
            else => {},
        }
    }
}

/// One memory page plus a data segment per distinct string constant. The
/// memory is exported so the host can read the bytes a (ptr, len) result
/// points at.
fn writeDataSection(gen: *WatGen) !void {
    if (gen.string_offsets.count() == 0) return;

    try gen.writeIndent();
    try gen.out.writeAll("(memory 1)\n");
    try gen.writeIndent();
    try gen.out.writeAll("(export \"memory\" (memory 0))\n");

    var it = gen.string_offsets.iterator();
    while (it.next()) |entry| {
        try gen.writeIndent();
        try gen.out.print("(data (i32.const {d}) \"", .{entry.value_ptr.*});
        try gen.writeEscapedBytes(entry.key_ptr.*.toSlice(gen.ip));
        try gen.out.writeAll("\")\n");
    }
}

/// WAT string-literal escaping: printable ASCII stays literal, quote and
/// backslash get escaped, everything else becomes a \XX hex escape.
fn writeEscapedBytes(gen: *WatGen, bytes: []const u8) !void {
    for (bytes) |byte| switch (byte) {
        '"' => try gen.out.writeAll("\\\""),
        '\\' => try gen.out.writeAll("\\\\"),
        0x20...0x21, 0x23...0x5B, 0x5D...0x7E => try gen.out.writeByte(byte),
        else => try gen.out.print("\\{x:0>2}", .{byte}),
    };
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
/// returns. A `number` is f64 at runtime (notes/number_literals.md).
fn resultType(gen: *const WatGen) []const u8 {
    const datas = gen.air.instructions.items(.data);
    const ret_ref = datas[gen.air.instructions.len - 1].un_op;
    const ip_index = ret_ref.toInterned() orelse @panic("inst-index refs not supported yet");
    return switch (gen.ip.indexToKey(ip_index)) {
        .float => "f64",
        // A string result is a (ptr, len) pair pointing into linear memory.
        .string => "i32 i32",
        // Sema's `coerce` at the ret boundary turns every int into an
        // interned float; no int value can reach codegen.
        .int => unreachable,
        .simple_type => @panic("type as value not supported yet"),
        .func_type => @panic("type as value not supported yet"),
        .@"extern" => @panic("type as value not supported yet"),
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
        .float => |float| {
            // `{d}` renders the shortest decimal form, so integral values
            // print as `4`, not `4.0` — the `number` print rule.
            try gen.writeIndent();
            try gen.out.print("f64.const {d}\n", .{float.storage.f64});
        },
        // Sema's `coerce` at the ret boundary turns every int into an
        // interned float; no int value can reach codegen.
        .int => unreachable,
        .simple_type => @panic("type as value not supported yet"),
        .func_type => @panic("type as value not supported yet"),
        .@"extern" => @panic("type as value not supported yet"),
        .string => |handle| {
            // (ptr, len) into linear memory; the data segment was emitted by
            // writeDataSection at the offset collectStrings assigned.
            const offset = gen.string_offsets.get(handle).?;
            try gen.writeIndent();
            try gen.out.print("i32.const {d}\n", .{offset});
            try gen.writeIndent();
            try gen.out.print("i32.const {d}\n", .{handle.length(gen.ip)});
        },
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

    try expectWatIndex(&ip, try ip.get(gpa, value), expected);
}

fn expectWatIndex(ip: *InternPool, ip_index: InternPool.Index, expected: []const u8) !void {
    const gpa = std.testing.allocator;

    var insts: std.MultiArrayList(Air.Inst) = .{};
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = .fromInterned(ip_index) } });
    var air = Air{ .instructions = insts.toOwnedSlice() };
    defer air.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &air, ip, &w);
    try std.testing.expectEqualStrings(expected, w.buffer[0..w.end]);
}

test "emit integral float result" {
    // The `number` print rule: integral values render as `-42`, not `-42.0`
    // (notes/number_literals.md). Valid WAT — the text format accepts
    // integer-looking tokens for float constants.
    try expectWat(.{ .float = .{ .ty = .comptime_float_type, .storage = .{ .f64 = -42.0 } } },
        \\(module
        \\  (func $main (result f64)
        \\    f64.const -42
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

test "emit string result" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);
    const ip_index = try ip.get(gpa, .{ .string = try ip.getString(gpa, "hi") });

    try expectWatIndex(&ip, ip_index,
        \\(module
        \\  (memory 1)
        \\  (export "memory" (memory 0))
        \\  (data (i32.const 0) "hi")
        \\  (func $main (result i32 i32)
        \\    i32.const 0
        \\    i32.const 2
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    );
}
