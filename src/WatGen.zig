//! Built with Claude — do not use in prod.
//! Emits WebAssembly text format (.wat) from Sema's AIR.
//! Stepping stone before a binary emitter.

const WatGen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Air = @import("Sema/Air.zig");
const Sema = @import("Sema.zig");
const InternPool = @import("InternPool.zig");
const NullTerminatedString = @import("string.zig").NullTerminatedString;

gpa: Allocator,
ip: *const InternPool,
out: *std.Io.Writer,
indent: u32 = 0,
/// String constants referenced by any body, mapped to their offset in linear
/// memory. Populated by `collectStrings` before anything is written.
string_offsets: std.AutoArrayHashMapUnmanaged(NullTerminatedString, u32) = .empty,
/// Defined functions' interned values mapped to their declared names, so a
/// call to one prints `call $name`.
func_names: std.AutoArrayHashMapUnmanaged(InternPool.Index, NullTerminatedString) = .empty,

// Per-function state, reset by `writeFunc`:

/// The function currently being emitted.
air: *const Air,
/// Every value-producing runtime instruction, mapped to its wasm local index.
/// The value is `local.set` right after it is produced and `local.get` at
/// each use — runtime values never stay on the operand stack, because stack
/// values cannot cross wasm block boundaries and interleave wrongly with
/// later constant pushes (argument order). An `arg` maps to its parameter's
/// local slot; declared locals follow the parameters.
locals: std.AutoArrayHashMapUnmanaged(Air.Inst.Index, u32) = .empty,
/// The wasm value type of each `(local …)` slot the current function
/// declares, in slot order (parameters not included — wasm gives them their
/// slots implicitly). Not all locals are f64 anymore: a Bool lives in an i32.
declared_local_types: std.ArrayList([]const u8) = .empty,

pub fn emit(gpa: Allocator, result: *const Sema.Result, ip: *const InternPool, out: *std.Io.Writer) !void {
    var gen = WatGen{ .gpa = gpa, .ip = ip, .out = out, .air = &result.main };
    defer gen.string_offsets.deinit(gpa);
    defer gen.func_names.deinit(gpa);
    defer gen.locals.deinit(gpa);
    defer gen.declared_local_types.deinit(gpa);

    for (result.funcs) |func| try gen.func_names.put(gpa, func.val, func.name);

    var string_offset: u32 = 0;
    for (result.funcs) |func| try gen.collectStrings(&func.air, &string_offset);
    try gen.collectStrings(&result.main, &string_offset);

    try out.writeAll("(module\n");
    gen.indent = 1;
    try gen.writeImports(result);
    try gen.writeDataSection();
    for (result.funcs) |func| {
        const fn_ty = gen.ip.indexToFuncType(gen.ip.typeOf(func.val)).?;
        try gen.writeFunc(func.name.toSlice(ip), fn_ty.param_types.get(ip), &func.air);
    }
    try gen.writeFunc("main", &.{}, &result.main);
    try gen.writeIndent();
    try out.writeAll("(export \"main\" (func $main))\n");
    try out.writeAll(")\n");
}

/// Assign every string constant referenced by `air` an offset in linear
/// memory, in order of first appearance, deduped by handle (equal strings
/// share one handle, so they share one data segment).
fn collectStrings(gen: *WatGen, air: *const Air, offset: *u32) !void {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (tags, datas) |tag, data| switch (tag) {
        .ret => try gen.collectStringRef(data.un_op, offset),
        // A call's arguments may be string constants; the callee is a
        // function, never a string.
        .call => for (callArgs(air, data)) |arg| try gen.collectStringRef(arg, offset),
        // Arithmetic/comparison operands are numbers (and `not`'s a Bool) —
        // Sema coerces before emitting; none can be a string constant.
        .add, .sub, .mul, .div, .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .not => {},
        .arg => {},
    };
}

/// Assign a wasm local to every instruction that produces a runtime value.
/// An `arg` takes its parameter's implicit slot; everything else gets a
/// declared local (typed by the instruction's result) after the parameters.
/// Unconditional — even an unused result is `local.set`, which keeps the
/// operand stack empty between statements.
fn collectLocals(gen: *WatGen, params_len: u32) !void {
    gen.locals.clearRetainingCapacity();
    gen.declared_local_types.clearRetainingCapacity();
    const tags = gen.air.instructions.items(.tag);
    const datas = gen.air.instructions.items(.data);
    for (tags, datas, 0..) |tag, data, i| {
        const inst: Air.Inst.Index = @enumFromInt(i);
        switch (tag) {
            .ret => {},
            .arg => try gen.locals.put(gen.gpa, inst, data.arg.index),
            .add, .sub, .mul, .div => try gen.addLocal(inst, params_len, "f64"),
            // Comparison results are Bool: i32 at runtime.
            .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte, .not => try gen.addLocal(inst, params_len, "i32"),
            .call => if (gen.air.typeOfIndex(inst, gen.ip).toIntern() != .void_type) {
                try gen.addLocal(inst, params_len, wasmType(gen.air.typeOfIndex(inst, gen.ip).toIntern()));
            },
        }
    }
}

fn addLocal(gen: *WatGen, inst: Air.Inst.Index, params_len: u32, wasm_ty: []const u8) !void {
    try gen.locals.put(gen.gpa, inst, params_len + @as(u32, @intCast(gen.declared_local_types.items.len)));
    try gen.declared_local_types.append(gen.gpa, wasm_ty);
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
fn callArgs(air: *const Air, data: Air.Inst.Data) []const Air.Inst.Ref {
    const extra = air.extra.items;
    const payload = data.pl_op.payload;
    const args_len = extra[payload]; // Air.Call.args_len is the first field
    return @ptrCast(extra[payload + 1 ..][0..args_len]);
}

/// Emit an `(import …)` for every distinct extern any body calls, before the
/// functions. The import module defaults to "host" (notes/functions.md).
/// Calls to defined functions need no import.
fn writeImports(gen: *WatGen, result: *const Sema.Result) !void {
    var seen: std.AutoArrayHashMapUnmanaged(NullTerminatedString, void) = .empty;
    defer seen.deinit(gen.gpa);

    for (result.funcs) |func| try gen.writeImportsIn(&func.air, &seen);
    try gen.writeImportsIn(&result.main, &seen);
}

fn writeImportsIn(
    gen: *WatGen,
    air: *const Air,
    seen: *std.AutoArrayHashMapUnmanaged(NullTerminatedString, void),
) !void {
    const tags = air.instructions.items(.tag);
    const datas = air.instructions.items(.data);
    for (tags, datas) |tag, data| {
        if (tag != .call) continue;
        const ext = switch (gen.ip.indexToKey(data.pl_op.operand.toInterned().?)) {
            .@"extern" => |ext| ext,
            .func => continue,
            else => unreachable,
        };
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
        .bool_type => "i32",
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

fn writeFunc(gen: *WatGen, name: []const u8, param_types: []const InternPool.Index, air: *const Air) !void {
    gen.air = air;
    try gen.collectLocals(@intCast(param_types.len));

    try gen.writeIndent();
    try gen.out.print("(func ${s}", .{name});
    for (param_types) |param| try gen.out.print(" (param {s})", .{wasmType(param)});
    // A void result has no wasm value type, so the clause is omitted entirely
    // rather than mapped — same gate as `writeImports`.
    const ret_ty = gen.resultType();
    if (ret_ty != .void_type) try gen.out.print(" (result {s})", .{wasmType(ret_ty)});
    try gen.out.writeAll("\n");
    gen.indent += 1;
    if (gen.declared_local_types.items.len != 0) {
        try gen.writeIndent();
        try gen.out.writeAll("(local");
        for (gen.declared_local_types.items) |local_ty| {
            try gen.out.writeByte(' ');
            try gen.out.writeAll(local_ty);
        }
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
            // Push each argument, then call the target by name — an extern's
            // import name, or a defined function's declared name.
            for (callArgs(gen.air, data)) |arg| try gen.writeRef(arg);
            const name = switch (gen.ip.indexToKey(data.pl_op.operand.toInterned().?)) {
                .@"extern" => |ext| ext.name,
                .func => gen.func_names.get(data.pl_op.operand.toInterned().?).?,
                else => unreachable,
            };
            try gen.writeIndent();
            try gen.out.print("call ${s}\n", .{name.toSlice(gen.ip)});
            try gen.writeLocalSet(inst);
        },
        // The parameter's value already lives in its local slot; the `arg`
        // instruction only established the mapping.
        .arg => {},
        .add, .sub, .mul, .div => {
            try gen.writeRef(data.bin_op.lhs);
            try gen.writeRef(data.bin_op.rhs);
            try gen.writeIndent();
            try gen.out.print("f64.{s}\n", .{@tagName(tag)});
            try gen.writeLocalSet(inst);
        },
        // The wasm f64 comparisons consume two f64 and yield an i32 (0/1) —
        // exactly Bool's runtime representation.
        .cmp_eq, .cmp_neq, .cmp_lt, .cmp_lte, .cmp_gt, .cmp_gte => {
            try gen.writeRef(data.bin_op.lhs);
            try gen.writeRef(data.bin_op.rhs);
            try gen.writeIndent();
            const op: []const u8 = switch (tag) {
                .cmp_eq => "eq",
                .cmp_neq => "ne",
                .cmp_lt => "lt",
                .cmp_lte => "le",
                .cmp_gt => "gt",
                .cmp_gte => "ge",
                else => unreachable,
            };
            try gen.out.print("f64.{s}\n", .{op});
            try gen.writeLocalSet(inst);
        },
        // `!b` on an i32 Bool is `b == 0`.
        .not => {
            try gen.writeRef(data.un_op);
            try gen.writeIndent();
            try gen.out.writeAll("i32.eqz\n");
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
        .func => @panic("function as value not supported yet"),
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
            // Bool is i32 at runtime: true = 1, false = 0.
            .true => {
                try gen.writeIndent();
                try gen.out.writeAll("i32.const 1\n");
            },
            .false => {
                try gen.writeIndent();
                try gen.out.writeAll("i32.const 0\n");
            },
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
    const result = Sema.Result{ .funcs = &.{}, .main = air };
    try WatGen.emit(gpa, &result, ip, &w);
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
    const result = Sema.Result{ .funcs = &.{}, .main = air };
    try WatGen.emit(gpa, &result, &ip, &w);
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
    const result = Sema.Result{ .funcs = &.{}, .main = air };
    try WatGen.emit(gpa, &result, &ip, &w);
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
    const result = Sema.Result{ .funcs = &.{}, .main = air };
    try WatGen.emit(gpa, &result, &ip, &w);
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

test "emit defined function and a call to it" {
    // fn add(x number) number { x + 1 } / main: add(2) — the defined fn gets
    // its own (func $add) with the param as local 0 and its declared local
    // after it; main calls it by name with no import.
    const gpa = std.testing.allocator;

    var ip: InternPool = .{};
    try ip.init(gpa);
    defer ip.deinit(gpa);

    const fn_ty = try ip.getFuncType(gpa, .{ .param_types = &.{.f64_type}, .return_type = .f64_type });
    const add_val = try ip.get(gpa, .{ .func = .{ .ty = fn_ty, .dir_inst = 5 } });
    const one = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 1 } } });
    const two = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 2 } } });

    // add's AIR:  %0 = arg(f64, 0);  %1 = add(%0, 1);  ret %1
    var fn_insts: std.MultiArrayList(Air.Inst) = .{};
    try fn_insts.append(gpa, .{ .tag = .arg, .data = .{ .arg = .{ .ty = .fromInterned(.f64_type), .index = 0 } } });
    const arg_ref = (@as(Air.Inst.Index, @enumFromInt(0))).toRef();
    try fn_insts.append(gpa, .{ .tag = .add, .data = .{ .bin_op = .{ .lhs = arg_ref, .rhs = .fromInterned(one) } } });
    const add_ref = (@as(Air.Inst.Index, @enumFromInt(1))).toRef();
    try fn_insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = add_ref } });
    var fn_air = Air{ .instructions = fn_insts.toOwnedSlice(), .extra = .empty };
    defer fn_air.deinit(gpa);

    // main's AIR:  %0 = call add(2);  ret %0
    var main_insts: std.MultiArrayList(Air.Inst) = .{};
    try main_insts.append(gpa, .{ .tag = .call, .data = .{ .pl_op = .{
        .operand = .fromInterned(add_val),
        .payload = 0,
    } } });
    const call_ref = (@as(Air.Inst.Index, @enumFromInt(0))).toRef();
    try main_insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = call_ref } });
    var main_extra: std.ArrayList(u32) = .empty;
    try main_extra.append(gpa, 1); // Air.Call.args_len
    try main_extra.append(gpa, @intFromEnum(Air.Inst.Ref.fromInterned(two)));
    var main_air = Air{ .instructions = main_insts.toOwnedSlice(), .extra = main_extra };
    defer main_air.deinit(gpa);

    const funcs = [_]Sema.Result.Func{.{
        .name = try ip.getString(gpa, "add"),
        .val = add_val,
        .air = fn_air,
    }};
    const result = Sema.Result{ .funcs = &funcs, .main = main_air };

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try WatGen.emit(gpa, &result, &ip, &w);
    try std.testing.expectEqualStrings(
        \\(module
        \\  (func $add (param f64) (result f64)
        \\    (local f64)
        \\    local.get 0
        \\    f64.const 1
        \\    f64.add
        \\    local.set 1
        \\    local.get 1
        \\    return
        \\  )
        \\  (func $main (result f64)
        \\    (local f64)
        \\    f64.const 2
        \\    call $add
        \\    local.set 0
        \\    local.get 0
        \\    return
        \\  )
        \\  (export "main" (func $main))
        \\)
        \\
    , w.buffer[0..w.end]);
}

test "emit runtime comparison with mixed local types" {
    // print(1) < 2: the call result is an f64 local, the comparison result a
    // Bool — an i32 local — so the local clause mixes value types.
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
    const two = try ip.get(gpa, .{ .float = .{ .ty = .f64_type, .storage = .{ .f64 = 2 } } });

    // AIR:  %0 = call print(1);  %1 = cmp_lt(%0, 2);  ret %1
    var insts: std.MultiArrayList(Air.Inst) = .{};
    try insts.append(gpa, .{ .tag = .call, .data = .{ .pl_op = .{
        .operand = .fromInterned(print_ext),
        .payload = 0,
    } } });
    const call_ref = (@as(Air.Inst.Index, @enumFromInt(0))).toRef();
    try insts.append(gpa, .{ .tag = .cmp_lt, .data = .{ .bin_op = .{
        .lhs = call_ref,
        .rhs = .fromInterned(two),
    } } });
    const cmp_ref = (@as(Air.Inst.Index, @enumFromInt(1))).toRef();
    try insts.append(gpa, .{ .tag = .ret, .data = .{ .un_op = cmp_ref } });

    var extra: std.ArrayList(u32) = .empty;
    try extra.append(gpa, 1); // print call: args_len
    try extra.append(gpa, @intFromEnum(Air.Inst.Ref.fromInterned(one)));

    var air = Air{ .instructions = insts.toOwnedSlice(), .extra = extra };
    defer air.deinit(gpa);

    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const result = Sema.Result{ .funcs = &.{}, .main = air };
    try WatGen.emit(gpa, &result, &ip, &w);
    try std.testing.expectEqualStrings(
        \\(module
        \\  (import "host" "print" (func $print (param f64) (result f64)))
        \\  (func $main (result i32)
        \\    (local f64 i32)
        \\    f64.const 1
        \\    call $print
        \\    local.set 0
        \\    local.get 0
        \\    f64.const 2
        \\    f64.lt
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
