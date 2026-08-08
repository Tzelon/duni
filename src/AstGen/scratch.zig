const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const AstGen = @import("../AstGen.zig");
const Dir = @import("../Dir.zig");

pub const Scratch = struct {
    astgen: *AstGen,
    scratch_top: u32,

    pub fn init(astgen: *AstGen) Scratch {
        return .{
            .astgen = astgen,
            .scratch_top = @intCast(astgen.scratch.items.len),
        };
    }

    pub fn reset(s: *Scratch) void {
        s.astgen.scratch.shrinkRetainingCapacity(s.scratch_top);
        s.* = undefined;
    }

    pub fn addSlice(s: *Scratch, len: u32) Allocator.Error!Slice {
        const start: u32 = @intCast(s.astgen.scratch.items.len);
        try s.astgen.scratch.resize(s.astgen.gpa, start + len);
        return .{ .start = start, .len = len };
    }

    pub fn addOptionalSlice(s: *Scratch, present: bool, len: u32) Allocator.Error!?Slice {
        if (!present) return null;
        return try addSlice(s, len);
    }

    /// Returns the slice containing all data added to this `Scratch`.
    pub fn all(s: *Scratch) Slice {
        const len = s.astgen.scratch.items.len - s.scratch_top;
        return .{ .start = s.scratch_top, .len = @intCast(len) };
    }
    const Slice = struct {
        start: u32,
        len: u32,
        fn get(s: Slice, astgen: *AstGen) []u32 {
            return astgen.scratch.items[s.start..][0..s.len];
        }
    };
};

pub const WipDecls = struct {
    astgen: *AstGen,
    slice: Scratch.Slice,
    index: u32,

    pub fn init(scratch: *Scratch, decls_len: u32) Allocator.Error!WipDecls {
        return .{
            .astgen = scratch.astgen,
            .slice = try scratch.addSlice(decls_len),
            .index = 0,
        };
    }

    pub fn finish(wip: *WipDecls) void {
        assert(wip.index == wip.slice.len);
        wip.* = undefined;
    }

    pub fn nextDecl(wip: *WipDecls, decl_inst: Dir.Inst.Index) void {
        wip.slice.get(wip.astgen)[wip.index] = @intFromEnum(decl_inst);
        wip.index += 1;
    }
};
