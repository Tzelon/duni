//! Prints DIR as a flat list of instructions, one per line.
//! Walks `Dir.instructions` linearly, mirroring `AstGen`'s emission order.

const Print = @This();
const std = @import("std");
const Ast = @import("Ast.zig");
const Dir = @import("Dir.zig");

w: *std.Io.Writer,
code: *const Dir,
tree: ?*const Ast,
parent_decl_node: Ast.Node.Index = .root,

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

pub fn print(code: *const Dir, tree: ?*const Ast, w: *std.Io.Writer) !void {
    var printer = Print{ .w = w, .code = code, .tree = tree };
    const tags = code.instructions.items(.tag);
    const datas = code.instructions.items(.data);
    for (tags, datas, 0..) |tag, data, i| {
        try printer.w.print("%{d} = ", .{i});
        try printer.writeInst(tag, data);
        try printer.w.writeByte('\n');
    }
}

fn writeInst(self: *Print, tag: Dir.Inst.Tag, data: Dir.Inst.Data) !void {
    try self.w.print("{s}(", .{@tagName(tag)});
    switch (tag) {
        .int => try self.writeInt(data),
        .negate => try self.writeUnNode(data),
        .add, .sub, .mul, .div => try self.writePlNodeBin(data),
    }
}

fn writeInt(self: *Print, data: Dir.Inst.Data) !void {
    try self.w.print("{d})", .{data.int});
}

fn writeUnNode(self: *Print, data: Dir.Inst.Data) !void {
    try self.writeRef(data.un_node.operand);
    try self.w.writeAll(")");
    try self.writeSrcNode(data.un_node.src_node);
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
    switch (ref) {
        .none => try self.w.writeAll("none"),
        .number_type => try self.w.writeAll("number_type"),
        _ => {
            if (ref.toIndex()) |idx| {
                try self.w.print("%{d}", .{@intFromEnum(idx)});
            } else {
                try self.w.print("ref({d})", .{@intFromEnum(ref)});
            }
        },
    }
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
