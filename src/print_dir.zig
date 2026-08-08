//! Prints DIR as a flat list of instructions, one per line.
//! Walks `Dir.instructions` linearly, mirroring `AstGen`'s emission order.

const Print = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const mem = std.mem;

const Ast = @import("Ast.zig");
const Dir = @import("Dir.zig");

w: *std.Io.Writer,
code: *const Dir,
tree: ?*const Ast,
parent_decl_node: Ast.Node.Index = .root,

gpa: Allocator,

/// Using `std.zig.findLineColumn` whenever we need to resolve a source location makes DIR
/// printing O(N^2), which can have drastic effects - taking a DIR dump from a few seconds to
/// many minutes. Since we're usually resolving source locations close to one another,
/// preserving state across source location resolutions speeds things up a lot.
line_col_cursor: LineColCursor = .{},

const LineColCursor = struct {
    line: usize = 0,
    column: usize = 0,
    line_start: usize = 0,
    off: usize = 0,

    fn find(cur: *LineColCursor, source: []const u8, want_offset: usize) std.zig.Loc {
        if (want_offset < cur.off) {
            // Go back to the start of this line
            cur.off = cur.line_start;
            cur.column = 0;

            while (want_offset < cur.off) {
                // Go back to the newline
                cur.off -= 1;

                // Seek to the start of the previous line
                while (cur.off > 0 and source[cur.off - 1] != '\n') {
                    cur.off -= 1;
                }
                cur.line_start = cur.off;
                cur.line -= 1;
            }
        }

        // Seek forward to `want_offset`, updating line/column along the way.
        while (cur.off < want_offset) : (cur.off += 1) {
            switch (source[cur.off]) {
                '\n' => {
                    cur.line += 1;
                    cur.column = 0;
                    cur.line_start = cur.off + 1;
                },
                else => cur.column += 1,
            }
        }

        // Compute end-of-line for `source_line` without mutating the cursor,
        // so subsequent same-line lookups don't see a stale `column`.
        var line_end = cur.off;
        while (line_end < source.len and source[line_end] != '\n') {
            line_end += 1;
        }

        return .{
            .line = cur.line,
            .column = cur.column,
            .source_line = source[cur.line_start..line_end],
        };
    }
};

pub fn print(code: *const Dir, tree: ?*const Ast, w: *std.Io.Writer, gpa: Allocator) !void {
    var printer = Print{ .w = w, .code = code, .tree = tree, .gpa = gpa };

    // Each instruction's source offsets are relative to its owning declaration
    // node. The linear walk can't tell which declaration an instruction belongs
    // to, so precompute the baseline node per instruction.
    const baselines = try printer.computeBaselines(gpa);
    defer gpa.free(baselines);

    const tags = code.instructions.items(.tag);
    const datas = code.instructions.items(.data);
    for (tags, datas, 0..) |tag, data, i| {
        printer.parent_decl_node = baselines[i];
        try printer.w.print("%{d} = ", .{i});
        try printer.writeInst(tag, data);
        try printer.w.writeByte('\n');
    }
}

/// Assigns each instruction the declaration node its source offsets are relative
/// to. Only `declaration` instructions shift the baseline; every instruction in
/// a declaration's type/value body (transitively) is relative to that
/// declaration's `src_node`. Everything else stays relative to `.root`.
fn computeBaselines(self: *Print, gpa: Allocator) ![]Ast.Node.Index {
    const baselines = try gpa.alloc(Ast.Node.Index, self.code.instructions.len);
    @memset(baselines, .root);
    for (self.code.instructions.items(.tag), 0..) |tag, i| {
        if (tag != .declaration) continue;
        const decl = self.code.getDeclaration(@enumFromInt(i));
        if (decl.type_body) |b| self.markBody(baselines, b, decl.src_node);
        if (decl.value_body) |b| self.markBody(baselines, b, decl.src_node);
    }
    return baselines;
}

/// Marks every instruction in `body` (and its nested sub-bodies) with `baseline`.
fn markBody(self: *Print, baselines: []Ast.Node.Index, body: []const Dir.Inst.Index, baseline: Ast.Node.Index) void {
    const tags = self.code.instructions.items(.tag);
    const datas = self.code.instructions.items(.data);
    for (body) |inst| {
        baselines[@intFromEnum(inst)] = baseline;
        switch (tags[@intFromEnum(inst)]) {
            .block, .block_inline => {
                const idx = datas[@intFromEnum(inst)].pl_node.payload_index;
                const body_len = self.code.extra[idx];
                self.markBody(baselines, self.code.bodySlice(idx + 1, body_len), baseline);
            },
            .param => {
                const idx = datas[@intFromEnum(inst)].pl_tok.payload_index;
                const ptype: Dir.Inst.Param.Type = @bitCast(self.code.extra[idx + 1]);
                self.markBody(baselines, self.code.bodySlice(idx + 2, ptype.body_len), baseline);
            },
            .func => {
                const idx = datas[@intFromEnum(inst)].pl_node.payload_index;
                const ret_ty: Dir.Inst.Func.RetTy = @bitCast(self.code.extra[idx]);
                const body_len = self.code.extra[idx + 2];
                // `ret_ty.body_len` slots hold the return type (1 = a single Ref).
                const body_start = idx + 3 + ret_ty.body_len;
                self.markBody(baselines, self.code.bodySlice(body_start, body_len), baseline);
            },
            // `break_inline` and leaf instructions have no sub-body.
            else => {},
        }
    }
}

fn writeInst(self: *Print, tag: Dir.Inst.Tag, data: Dir.Inst.Data) !void {
    // Extended instructions print their opcode, not the `extended` wrapper.
    if (tag == .extended) return self.writeExtended(data);

    try self.w.print("{s}(", .{@tagName(tag)});
    switch (tag) {
        .int_big => try self.writeIntBig(data),
        .float => try self.writeFloat(data),
        .int => try self.writeInt(data),
        .negate => try self.writeUnNode(data),
        .str => try self.writeStr(data),
        .decl_val => try self.writeStrTok(data),
        .add, .sub, .mul, .div => try self.writePlNodeBin(data),
        .block, .block_inline => try self.writeBlock(data),
        .break_inline => try self.writeBreak(data),
        .declaration => try self.writeDeclaration(data),
        .func => try self.writeFunc(data),
        .param => try self.writeParam(data),
        .call => try self.writeCall(data),
        .extended => unreachable,
    }
}

fn writeExtended(self: *Print, data: Dir.Inst.Data) !void {
    const extended = data.extended;
    try self.w.print("{s}(", .{@tagName(extended.opcode)});
    switch (extended.opcode) {
        .module_decl => try self.writeModuleDecl(),
    }
}

fn writeModuleDecl(self: *Print) !void {
    // Only the root module exists today, so `mainBody` (Dir's one payload
    // decoder) is the body.
    const body = self.code.mainBody();
    for (body, 0..) |inst, i| {
        if (i > 0) try self.w.writeAll(", ");
        try self.writeRef(inst.toRef());
    }
    try self.w.writeAll(")");
}

fn writeBlock(self: *Print, data: Dir.Inst.Data) !void {
    const idx = data.pl_node.payload_index;
    const body_len = self.code.extra[idx];
    for (0..body_len) |i| {
        if (i > 0) try self.w.writeAll(", ");
        const inst_idx: Dir.Inst.Index = @enumFromInt(self.code.extra[idx + 1 + i]);
        try self.writeRef(inst_idx.toRef());
    }
    try self.w.writeAll(")");
    try self.writeSrcNode(data.pl_node.src_node);
}

fn writeBreak(self: *Print, data: Dir.Inst.Data) !void {
    // Break payload layout: { operand_src_node, block_inst }.
    const payload_index = data.@"break".payload_index;
    const block_inst: Dir.Inst.Index = @enumFromInt(self.code.extra[payload_index + 1]);
    try self.writeRef(block_inst.toRef());
    try self.w.writeAll(", ");
    try self.writeRef(data.@"break".operand);
    try self.w.writeAll(")");
}

fn writeDeclaration(self: *Print, data: Dir.Inst.Data) !void {
    _ = data;
    // TODO: decode the name and type/value bodies once the `Declaration` payload
    // carries a flags word. Until then those fields are not decodable here.
    try self.w.writeAll(")");
}

fn writeParam(self: *Print, data: Dir.Inst.Data) !void {
    // Param payload: { name, type }, followed by `type.body_len` body instructions.
    const payload_index = data.pl_tok.payload_index;
    const name: Dir.NullTerminatedString = @enumFromInt(self.code.extra[payload_index]);
    const param_type: Dir.Inst.Param.Type = @bitCast(self.code.extra[payload_index + 1]);

    try self.w.print("{s}, {{", .{self.code.nullTerminatedString(name)});
    const body_start = payload_index + 2;
    for (0..param_type.body_len) |i| {
        if (i > 0) try self.w.writeAll(", ");
        const inst: Dir.Inst.Index = @enumFromInt(self.code.extra[body_start + i]);
        try self.writeRef(inst.toRef());
    }
    try self.w.writeAll("})");
}

fn writeFunc(self: *Print, data: Dir.Inst.Data) !void {
    // Func payload: { ret_ty, param_block, body_len }, then the trailing return
    // type (per `ret_ty`) followed by `body_len` body instructions.
    const payload_index = data.pl_node.payload_index;
    const ret_ty: Dir.Inst.Func.RetTy = @bitCast(self.code.extra[payload_index]);
    const param_block: Dir.Inst.Index = @enumFromInt(self.code.extra[payload_index + 1]);
    const body_len = self.code.extra[payload_index + 2];
    var extra_index = payload_index + 3;

    try self.writeRef(param_block.toRef());

    try self.w.writeAll(", ret_ty=");
    switch (ret_ty.body_len) {
        0 => try self.w.writeAll("void"),
        1 => {
            const ret_ref: Dir.Inst.Ref = @enumFromInt(self.code.extra[extra_index]);
            extra_index += 1;
            try self.writeRef(ret_ref);
        },
        // Duni never emits a multi-instruction return-type body.
        else => unreachable,
    }

    if (body_len > 0) {
        try self.w.writeAll(", body={");
        for (0..body_len) |i| {
            if (i > 0) try self.w.writeAll(", ");
            const inst: Dir.Inst.Index = @enumFromInt(self.code.extra[extra_index]);
            extra_index += 1;
            try self.writeRef(inst.toRef());
        }
        try self.w.writeAll("}");
    }

    try self.w.writeAll(")");
    try self.writeSrcNode(data.pl_node.src_node);
}

fn writeInt(self: *Print, data: Dir.Inst.Data) !void {
    try self.w.print("{d})", .{data.int});
}

fn writeIntBig(self: *Print, data: Dir.Inst.Data) !void {
    const str = data.str;
    const byte_count = str.len * @sizeOf(std.math.big.Limb);
    const limb_bytes = self.code.string_bytes[@intFromEnum(str.start)..][0..byte_count];
    // limb_bytes is not aligned properly; we must allocate and copy the bytes
    // in order to accomplish this.
    const limbs = try self.gpa.alloc(std.math.big.Limb, str.len);
    defer self.gpa.free(limbs);

    @memcpy(mem.sliceAsBytes(limbs), limb_bytes);
    const big_int: std.math.big.int.Const = .{
        .limbs = limbs,
        .positive = true,
    };
    const as_string = try big_int.toStringAlloc(self.gpa, 10, .lower);
    defer self.gpa.free(as_string);
    try self.w.print("{s})", .{as_string});
}

fn writeFloat(self: *Print, data: Dir.Inst.Data) !void {
    const number = data.float;
    try self.w.print("{d})", .{number});
}

fn writeUnNode(self: *Print, data: Dir.Inst.Data) !void {
    try self.writeRef(data.un_node.operand);
    try self.w.writeAll(")");
    try self.writeSrcNode(data.un_node.src_node);
}

fn writeStr(self: *Print, data: Dir.Inst.Data) !void {
    const str = data.str.get(self.code);
    try self.w.print("{s})", .{str});
}

fn writeStrTok(self: *Print, data: Dir.Inst.Data) !void {
    const str = data.str_tok.get(self.code);
    try self.w.print("{s})", .{str});
}

fn writeCall(self: *Print, data: Dir.Inst.Data) !void {
    // Call payload: { callee, args_len }, then `args_len` body end-offsets
    // (each relative to the start of this trailing region), then the arg
    // bodies. Body 0 begins just past the offset table; arg i's body ends at
    // `offsets[i]`.
    const payload_index = data.pl_node.payload_index;
    const args_len = self.code.extra[payload_index];
    const callee: Dir.Inst.Ref = @enumFromInt(self.code.extra[payload_index + 1]);

    try self.writeRef(callee);

    const table_start = payload_index + 2;
    var body_start = args_len;
    for (0..args_len) |i| {
        const body_end = self.code.extra[table_start + i];
        try self.w.writeAll(", {");
        for (body_start..body_end) |j| {
            if (j > body_start) try self.w.writeAll(", ");
            const inst: Dir.Inst.Index = @enumFromInt(self.code.extra[table_start + j]);
            try self.writeRef(inst.toRef());
        }
        try self.w.writeAll("}");
        body_start = body_end;
    }

    try self.w.writeAll(")");
    try self.writeSrcNode(data.pl_node.src_node);
}

fn writePlNodeBin(self: *Print, data: Dir.Inst.Data) !void {
    const idx = data.pl_node.payload_index;
    const lhs: Dir.Inst.Ref = @enumFromInt(self.code.extra[idx]);
    const rhs: Dir.Inst.Ref = @enumFromInt(self.code.extra[idx + 1]);
    try self.writeRef(lhs);
    try self.w.writeAll(", ");
    try self.writeRef(rhs);
    try self.w.writeAll(")");
    try self.writeSrcNode(data.pl_node.src_node);
}

fn writeRef(self: *Print, ref: Dir.Inst.Ref) !void {
    if (ref.toIndexAllowNone()) |idx| {
        return self.w.print("%{d}", .{@intFromEnum(idx)});
    }
    // `none` and the static InternPool refs are exactly the named tags,
    // so new statics print correctly without touching this function.
    if (std.enums.tagName(Dir.Inst.Ref, ref)) |name| {
        return self.w.writeAll(name);
    }
    try self.w.print("ref({d})", .{@intFromEnum(ref)});
}

fn writeSrcNode(self: *Print, src_node: Ast.Node.Offset) !void {
    const tree = self.tree orelse return;
    const abs_node = src_node.toAbsolute(self.parent_decl_node);
    const span = tree.nodeToSpan(abs_node);
    const start = self.line_col_cursor.find(tree.source, span.start);
    const end = self.line_col_cursor.find(tree.source, span.end);
    try self.w.print(" node_offset:{d}:{d} to :{d}:{d}", .{
        start.line + 1, start.column + 1,
        end.line + 1,   end.column + 1,
    });
}
