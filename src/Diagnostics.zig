//! Sema error collector, and error renderer.
//! Parse keep errors in `tree.errors`, and AstGen writes them into `Dir`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Span = Ast.Span;

const Dir = @import("Dir.zig");

const Diag = @This();

gpa: Allocator,
errors: std.ArrayList(ErrorMsg) = .empty,

pub const SrcLoc = struct {
    /// This instruction provides the source node locations are resolved relative to.
    /// This must be valid even if `relative` is an absolute value, since it is required to
    /// determine the file which the `LazySrcLoc` refers to.
    base_inst: Dir.Inst.Index,
    /// This field determines the source location relative to `base_node_inst`.
    offset: Offset,

    pub const Offset = union(enum) {
        /// The source location points to a byte offset within a source file,
        /// offset from 0. The source file is determined contextually.
        byte_abs: u32,
        /// The source location points to an AST node, which is this value offset
        /// from its containing base node AST index.
        node_offset: TracedOffset,
        /// The source location points to the callee expression of a function
        /// call expression, found by taking this AST node index offset from the containing
        /// base node, which points to a function call AST node. Next, navigate
        /// to the callee expression.
        node_offset_call_func: Ast.Node.Offset,
    };
};

/// This struct holds data necessary to construct API-facing `AllErrors.Message`.
/// Its memory is managed with the general purpose allocator so that they
/// can be created and destroyed in response to incremental updates.
pub const ErrorMsg = struct {
    src_loc: LazySrcLoc,
    msg: []const u8,
    notes: []ErrorMsg = &.{},

    pub fn init(gpa: Allocator, src_loc: LazySrcLoc, comptime format: []const u8, args: anytype) !ErrorMsg {
        return .{
            .src_loc = src_loc,
            .msg = try std.fmt.allocPrint(gpa, format, args),
        };
    }

    pub fn deinit(err_msg: *ErrorMsg, gpa: Allocator) void {
        for (err_msg.notes) |*note| {
            note.deinit(gpa);
        }
        gpa.free(err_msg.notes);
        gpa.free(err_msg.msg);
        err_msg.* = undefined;
    }

    pub fn create(
        gpa: Allocator,
        src_loc: LazySrcLoc,
        comptime format: []const u8,
        args: anytype,
    ) !*ErrorMsg {
        const err_msg = try gpa.create(ErrorMsg);
        errdefer gpa.destroy(err_msg);
        err_msg.* = try ErrorMsg.init(gpa, src_loc, format, args);
        return err_msg;
    }
};

pub fn addError(diag: *Diag, src: SrcLoc, comptime format: []const u8, args: anytype) Allocator.Error!void {
    try diag.errors.ensureUnusedCapacity(diag.gpa, 1);
    const msg = ErrorMsg.create(diag.gpa, src, format, args);
    diag.errors.appendAssumeCapacity(msg);
}

pub fn deinit(diag: *Diag) void {
    for (diag.errors.items) |*err| {
        err.deinit(diag.gpa);
    }

    diag.errors.deinit(diag.gpa);
}
