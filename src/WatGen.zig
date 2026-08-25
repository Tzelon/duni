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
/// Every value-producing runtime instruction, mapped to its wasm local index.
/// The value is `local.set` right after it is produced and `local.get` at
/// each use — runtime values never stay on the operand stack, because stack
/// values cannot cross wasm block boundaries and interleave wrongly with
/// later constant pushes (argument order). Populated by `collectLocals`.
locals: std.AutoArrayHashMapUnmanaged(Air.Inst.Index, u32) = .empty,

pub fn emit(gpa: Allocator, air: *const Air, ip: *const InternPool, out: *std.Io.Writer) !void {
    var gen = WatGen{ .gpa = gpa, .air = air, .ip = ip, .out = out };
    defer gen.string_offsets.deinit(gpa);
    defer gen.locals.deinit(gpa);

    try gen.collectStrings();
    try gen.collectLocals();

    try out.writeAll("(module\n");
    gen.indent = 1;
    try gen.writeImports();
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
    for (tags, datas) |tag, data| switch (tag) {
        .ret => try gen.collectStringRef(data.un_op, &offset),
        // A call's arguments may be string constants; the callee is an extern,
        // never a string.
        .call => for (gen.callArgs(data)) |arg| try gen.collectStringRef(arg, &offset),
        // Arithmetic operands are numbers — Sema coerces before emitting.
        .add, .sub, .mul, .div => {},
    };
}

/// Assign a wasm local to every instruction that produces a runtime value.
/// Unconditional — even an unused result is `local.set`, which keeps the
/// operand stack empty between statements. All runtime values are `number`
/// (f64) today, so every local is f64.
fn collectLocals(gen: *WatGen) !void {
    const tags = gen.air.instructions.items(.tag);
    for (tags, 0..) |tag, i| {
        const inst: Air.Inst.Index = @enumFromInt(i);
        const produces_value = switch (tag) {
            .ret => false,
            .add, .sub, .mul, .div => true,
            .call => gen.air.typeOfIndex(inst, gen.ip).toIntern() != .void_type,
        };
        if (!produces_value) continue;
        try gen.locals.put(gen.gpa, inst, @intCast(gen.locals.count()));
    }
}

/// Assign `ref` a data-segment offset if it is a not-yet-seen string constant.
fn collectStringRef(gen: *WatGen, ref: Air.Inst.Ref, offset: *u32) !void {
    const ip_index = ref.toInterned() orelse return;
    switch (gen.ip.indexToKey(ip_index)) {
        .string => |handle| {
            const gop = try gen.string_offsets.getOrPut(gen.gpa, handle);
            if (!gop.found_existing) {
                gop.value_ptr.* = offset.*;
                offset.* += handle.length(gen.ip);
            }
        },
        else => {},
    }
}

/// The argument refs trailing a `call`'s `Air.Call` header in `air.extra`.
fn callArgs(gen: *const WatGen, data: Air.Inst.Data) []const Air.Inst.Ref {
    const extra = gen.air.extra.items;
    const payload = data.pl_op.payload;
    const args_len = extra[payload]; // Air.Call.args_len is the first field
    return @ptrCast(extra[payload + 1 ..][0..args_len]);
}

/// Emit an `(import …)` for every distinct extern a `call` references, before
/// the functions. The import module defaults to "host" (notes/functions.md).
fn writeImports(gen: *WatGen) !void {
    var seen: std.AutoArrayHashMapUnmanaged(NullTerminatedString, void) = .empty;
    defer seen.deinit(gen.gpa);

    const tags = gen.air.instructions.items(.tag);
    const datas = gen.air.instructions.items(.data);
    for (tags, datas) |tag, data| {
        if (tag != .call) continue;
        const ext = gen.ip.indexToKey(data.pl_op.operand.toInterned().?).@"extern";
        if ((try seen.getOrPut(gen.gpa, ext.name)).found_existing) continue;

        const fn_ty = gen.ip.indexToKey(ext.ty).func_type;
        const name = ext.name.toSlice(gen.ip);
        const module = ext.lib_name.toSlice(gen.ip) orelse "host";

        try gen.writeIndent();
        try gen.out.print("(import \"{s}\" \"{s}\" (func ${s}", .{ module, name, name });
        for (fn_ty.param_types.get(gen.ip)) |param| {
            try gen.out.print(" (param {s})", .{wasmType(param)});
        }
        if (fn_ty.return_type != .void_type) {
            try gen.out.print(" (result {s})", .{wasmType(fn_ty.return_type)});
        }
        try gen.out.writeAll("))\n");
    }
}

/// Map a Duni type to its wasm value type(s). A `number` is f64 at runtime
/// (notes/number_literals.md); a string is a (ptr, len) pair.
fn wasmType(ty: InternPool.Index) []const u8 {
    return switch (ty) {
        .f64_type, .comptime_float_type => "f64",
        .string_type => "i32 i32",
        else => @panic("unsupported wasm type"),
    };
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
    try gen.out.writeAll("(func $main");
    // A void result has no wasm value type, so the clause is omitted entirely
    // rather than mapped — same gate as `writeImports`.
    const ret_ty = gen.resultType();
    if (ret_ty != .void_type) try gen.out.print(" (result {s})", .{wasmType(ret_ty)});
    try gen.out.writeAll("\n");
    gen.indent += 1;
    if (gen.locals.count() != 0) {
        try gen.writeIndent();
        try gen.out.writeAll("(local");
        for (0..gen.locals.count()) |_| try gen.out.writeAll(" f64");
        try gen.out.writeAll(")\n");
    }
    try gen.writeBody();
    gen.indent -= 1;
    try gen.writeIndent();
    try gen.out.writeAll(")\n");
}

/// The type of `main`'s result, from the value the final `ret` returns — via
/// `air.typeOf`, so a runtime call result (an AIR instruction ref, not an
/// interned value) resolves too. `Sema.analyze` always appends the `ret` last,
/// so the terminator is found by position; the assert keeps that checked.
fn resultType(gen: *const WatGen) InternPool.Index {
    const last = gen.air.instructions.len - 1;
    std.debug.assert(gen.air.instructions.items(.tag)[last] == .ret);
    const ret_ref = gen.air.instructions.items(.data)[last].un_op;
    return gen.air.typeOf(ret_ref, gen.ip).toIntern();
}

fn writeBody(gen: *WatGen) !void {
    const tags = gen.air.instructions.items(.tag);
    const datas = gen.air.instructions.items(.data);
    for (tags, datas, 0..) |tag, data, i| try gen.writeInst(tag, data, @enumFromInt(i));
}

fn writeInst(gen: *WatGen, tag: Air.Inst.Tag, data: Air.Inst.Data, inst: Air.Inst.Index) !void {
    switch (tag) {
        .ret => {
            try gen.writeRef(data.un_op);
            try gen.writeIndent();
            try gen.out.writeAll("return\n");
        },
        .call => {
            // Push each argument, then call the import by name.
            for (gen.callArgs(data)) |arg| try gen.writeRef(arg);
            const ext = gen.ip.indexToKey(data.pl_op.operand.toInterned().?).@"extern";
            try gen.writeIndent();
            try gen.out.print("call ${s}\n", .{ext.name.toSlice(gen.ip)});
            try gen.writeLocalSet(inst);
        },
        .add, .sub, .mul, .div => {
            try gen.writeRef(data.bin_op.lhs);
            try gen.writeRef(data.bin_op.rhs);
            try gen.writeIndent();
            try gen.out.print("f64.{s}\n", .{@tagName(tag)});
            try gen.writeLocalSet(inst);
        },
    }
}

/// Store the instruction's result in its local, if it has one (`.ret`
/// consumes the stack itself; a void call leaves nothing to store).
fn writeLocalSet(gen: *WatGen, inst: Air.Inst.Index) !void {
    const local = gen.locals.get(inst) orelse return;
    try gen.writeIndent();
    try gen.out.print("local.set {d}\n", .{local});
}

fn writeRef(gen: *WatGen, ref: Air.Inst.Ref) !void {
    const ip_index = ref.toInterned() orelse {
        const inst = ref.toIndex().?;
        // A void result (a call to a void extern) has no runtime
        // representation — nothing to push.
        if (gen.air.typeOfIndex(inst, gen.ip).toIntern() == .void_type) return;
        // A runtime AIR result lives in the local `collectLocals` assigned it.
        try gen.writeIndent();
        try gen.out.print("local.get {d}\n", .{gen.locals.get(inst).?});
        return;
    };
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
        .simple_value => |value| switch (value) {
            // `void` has no runtime representation — nothing to push.
            .void => {},
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
    var air = Air{ .instructions = insts.toOwnedSlice(), .extra = .empty };
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

test "emit call to extern" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    // extern fn print(x number) number
    const params = [_]InternPool.Index{.f64_type};
    const fn_ty = try ip.getFuncType(gpa, .{ .param_types = &params, .return_type = .f64_type });
    const print_ext = try ip.get(gpa, .{ .@"extern" = .{
        .name = try ip.getString(gpa, "print"),
        .ty = fn_ty,
        .lib_name = .none,
    } });
    const arg = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 42 } } });

    // AIR:  %0 = call print(42);  ret %0
    var insts: std.MultiArrayList(Air.Inst) = .{};
    try insts.append(gpa, .{ .tag = .call, .data = .{ .pl_op = .{
        .operand = .fromInterned(print_ext),
        .payload = 0,
    } } });
    const call_ref = (@as(Air.Inst.Index, @enumFromInt(0))).toRef();
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = call_ref } });

    var extra: std.ArrayList(u32) = .empty;
    try extra.append(gpa, 1); // Air.Call.args_len
    try extra.append(gpa, @intFromEnum(Air.Inst.Ref.fromInterned(arg)));

    var air = Air{ .instructions = insts.toOwnedSlice(), .extra = extra };
    defer air.deinit(gpa);

    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &air, &ip, &w);
    try std.testing.expectEqualStrings(
        \\(module
        \\  (import "host" "print" (func $print (param f64) (result f64)))
        \\  (func $main (result f64)
        \\    (local f64)
        \\    f64.const 42
        \\    call $print
        \\    local.set 0
        \\    local.get 0
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    , w.buffer[0..w.end]);
}

test "emit call with a runtime argument after a comptime one" {
    // sub(10, print(3)): the runtime arg (%0) is produced before the comptime
    // 10 is pushed, so it must round-trip through a local — leaving it on the
    // operand stack would reverse the argument order.
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const unary_ty = try ip.getFuncType(gpa, .{ .param_types = &.{.f64_type}, .return_type = .f64_type });
    const binary_ty = try ip.getFuncType(gpa, .{ .param_types = &.{ .f64_type, .f64_type }, .return_type = .f64_type });
    const print_ext = try ip.get(gpa, .{ .@"extern" = .{
        .name = try ip.getString(gpa, "print"),
        .ty = unary_ty,
        .lib_name = .none,
    } });
    const sub_ext = try ip.get(gpa, .{ .@"extern" = .{
        .name = try ip.getString(gpa, "sub"),
        .ty = binary_ty,
        .lib_name = .none,
    } });
    const three = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 3 } } });
    const ten = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 10 } } });

    // AIR:  %0 = call print(3);  %1 = call sub(10, %0);  ret %1
    var insts: std.MultiArrayList(Air.Inst) = .{};
    try insts.append(gpa, .{ .tag = .call, .data = .{ .pl_op = .{
        .operand = .fromInterned(print_ext),
        .payload = 0,
    } } });
    try insts.append(gpa, .{ .tag = .call, .data = .{ .pl_op = .{
        .operand = .fromInterned(sub_ext),
        .payload = 2,
    } } });
    const inner_ref = (@as(Air.Inst.Index, @enumFromInt(0))).toRef();
    const outer_ref = (@as(Air.Inst.Index, @enumFromInt(1))).toRef();
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = outer_ref } });

    var extra: std.ArrayList(u32) = .empty;
    try extra.append(gpa, 1); // print call: args_len
    try extra.append(gpa, @intFromEnum(Air.Inst.Ref.fromInterned(three)));
    try extra.append(gpa, 2); // sub call: args_len
    try extra.append(gpa, @intFromEnum(Air.Inst.Ref.fromInterned(ten)));
    try extra.append(gpa, @intFromEnum(inner_ref));

    var air = Air{ .instructions = insts.toOwnedSlice(), .extra = extra };
    defer air.deinit(gpa);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &air, &ip, &w);
    try std.testing.expectEqualStrings(
        \\(module
        \\  (import "host" "print" (func $print (param f64) (result f64)))
        \\  (import "host" "sub" (func $sub (param f64) (param f64) (result f64)))
        \\  (func $main (result f64)
        \\    (local f64 f64)
        \\    f64.const 3
        \\    call $print
        \\    local.set 0
        \\    f64.const 10
        \\    local.get 0
        \\    call $sub
        \\    local.set 1
        \\    local.get 1
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    , w.buffer[0..w.end]);
}

test "emit runtime arithmetic" {
    // print(1) + 1: the runtime lhs comes back from its local, the comptime
    // rhs is a constant, and the result gets its own local.
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const unary_ty = try ip.getFuncType(gpa, .{ .param_types = &.{.f64_type}, .return_type = .f64_type });
    const print_ext = try ip.get(gpa, .{ .@"extern" = .{
        .name = try ip.getString(gpa, "print"),
        .ty = unary_ty,
        .lib_name = .none,
    } });
    const one = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 1 } } });

    // AIR:  %0 = call print(1);  %1 = add(%0, 1);  ret %1
    var insts: std.MultiArrayList(Air.Inst) = .{};
    try insts.append(gpa, .{ .tag = .call, .data = .{ .pl_op = .{
        .operand = .fromInterned(print_ext),
        .payload = 0,
    } } });
    const call_ref = (@as(Air.Inst.Index, @enumFromInt(0))).toRef();
    try insts.append(gpa, .{ .tag = .add, .data = .{ .bin_op = .{
        .lhs = call_ref,
        .rhs = .fromInterned(one),
    } } });
    const add_ref = (@as(Air.Inst.Index, @enumFromInt(1))).toRef();
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = add_ref } });

    var extra: std.ArrayList(u32) = .empty;
    try extra.append(gpa, 1); // print call: args_len
    try extra.append(gpa, @intFromEnum(Air.Inst.Ref.fromInterned(one)));

    var air = Air{ .instructions = insts.toOwnedSlice(), .extra = extra };
    defer air.deinit(gpa);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &air, &ip, &w);
    try std.testing.expectEqualStrings(
        \\(module
        \\  (import "host" "print" (func $print (param f64) (result f64)))
        \\  (func $main (result f64)
        \\    (local f64 f64)
        \\    f64.const 1
        \\    call $print
        \\    local.set 0
        \\    local.get 0
        \\    f64.const 1
        \\    f64.add
        \\    local.set 1
        \\    local.get 1
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    , w.buffer[0..w.end]);
}

test "emit void result" {
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    // `void` has no wasm value type, so `main` gets no `(result …)` clause and
    // nothing is pushed before the `return`.
    try expectWatIndex(&ip, .void_value,
        \\(module
        \\  (func $main
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    );
}
