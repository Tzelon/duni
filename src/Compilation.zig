const Compilation = @This();
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const fs = std.fs;
const log = std.log.scoped(.compilation);
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

const ErrorBundle = @import("ErrorBundle.zig");
const InternPool = @import("InternPool.zig");
const Ast = @import("Ast.zig");
const AstGen = @import("AstGen.zig");
const Dir = @import("Dir.zig");

/// General-purpose allocator. Used for both temporary and long-term storage.
gpa: Allocator,
file: *File,

/// Stores all Type and Value objects.
intern_pool: InternPool = .empty,
io: Io,

/// This tracks files which triggered errors when generating AST/DIR.
/// If not `null`, the value is a retryable error (the file status is guaranteed
/// to be `.retryable_failure`). Otherwise, the file status is `.astgen_failure`
/// or `.success`, and there are ZIR errors which should be printed.
/// We just store a `[]u8` instead of a full `*ErrorMsg`, because the source
/// location is always the entire file. The `[]u8` memory is owned by the map
/// and allocated into `gpa`.
failed_files: std.array_hash_map.Auto(File.Index, ?[]u8) = .empty,

/// If `true`, then semantic analysis must not occur on this update due to AstGen errors.
/// Essentially the entire pipeline after AstGen, including Sema and codegen, is skipped.
skip_analysis_this_update: bool = false,

pub const File = struct {
    status: enum {
        /// We have not yet attempted to load this file.
        never_loaded,
        /// This file has failed parsing AstGen.
        /// There is guaranteed to be a `failed_files` entry, which may or may not have messages.
        astgen_failure,
        /// Parsing and AstGen/ZonGen of this file has succeeded.
        /// There may still be a `failed_files` entry, e.g. for non-fatal AstGen errors.
        success,
    },

    /// The path of this file. It is important that this path has a "canonical form" because files
    /// are deduplicated based on path; `Compilation.Path` guarantees this. Owned by this `File`,
    /// allocated into `gpa`.
    path: Path,

    /// Populated only when emitting error messages; see `getSource`.
    source: ?[:0]const u8,
    /// Populated only when emitting error messages; see `getTree`.
    tree: ?Ast,

    dir: ?Dir,

    pub fn unload(file: *File, gpa: Allocator) void {
        file.unloadTree(gpa);
        file.unloadSource(gpa);
        file.unloadDir(gpa);
    }

    pub fn unloadTree(file: *File, gpa: Allocator) void {
        if (file.tree) |*tree| {
            tree.deinit(gpa);
            file.tree = null;
        }
    }

    pub fn unloadSource(file: *File, gpa: Allocator) void {
        if (file.source) |source| {
            gpa.free(source);
            file.source = null;
        }
    }

    pub fn unloadDir(file: *File, gpa: Allocator) void {
        if (file.dir) |*dir| {
            dir.deinit(gpa);
            file.dir = null;
        }
    }

    pub const GetSourceError = error{
        OutOfMemory,
        FileChanged,
    } || std.Io.File.OpenError || std.Io.File.Reader.Error;

    /// This must only be called in error conditions where `stat` *is* populated. It returns the
    /// contents of the source file, assuming the stat has not changed since it was originally
    /// loaded.
    pub fn getSource(file: *File, comp: *const Compilation) GetSourceError![:0]const u8 {
        const gpa = comp.gpa;
        const io = comp.io;

        if (file.source) |source| return source;

        switch (file.status) {
            .never_loaded => unreachable, // stat must be populated
            .astgen_failure, .success => {},
        }

        var f = f: {
            const dir, const sub_path = file.path.openInfo();
            break :f try dir.openFile(io, sub_path, .{});
        };
        defer f.close(io);

        const stat = f.stat(io) catch |err| switch (err) {
            error.Streaming => {
                // Since `file.stat` is populated, this was previously a file stream; since it is
                // now not a file stream, it must have changed.
                return error.FileChanged;
            },
            else => |e| return e,
        };

        const source = try gpa.allocSentinel(u8, @intCast(stat.size), 0);
        errdefer gpa.free(source);

        var file_reader = f.reader(io, &.{});
        file_reader.size = stat.size;
        file_reader.interface.readSliceAll(source) catch return file_reader.err.?;

        file.source = source;
        errdefer comptime unreachable; // don't error after populating `source`

        return source;
    }

    /// This must only be called in error conditions where `stat` *is* populated. It returns the
    /// parsed AST of the source file, assuming the stat has not changed since it was originally
    /// loaded.
    pub fn getTree(file: *File, comp: *const Compilation) GetSourceError!*const Ast {
        if (file.tree) |*tree| return tree;

        const source = try file.getSource(comp);
        file.tree = try .parse(comp.gpa, source);
        return &file.tree.?;
    }

    pub const Index = InternPool.FileIndex;

    pub fn errorBundleWholeFileSrc(
        file: *File,
        comp: *const Compilation,
        eb: *ErrorBundle.Wip,
    ) Allocator.Error!ErrorBundle.SourceLocationIndex {
        return eb.addSourceLocation(.{
            .src_path = try eb.printString("{f}", .{file.path.fmt(comp)}),
            .span_start = 0,
            .span_main = 0,
            .span_end = 0,
            .line = 0,
            .column = 0,
            .source_line = 0,
        });
    }
    /// Asserts that the tree has already been loaded with `getTree`.
    pub fn errorBundleTokenSrc(
        file: *File,
        tok: Ast.TokenIndex,
        comp: *const Compilation,
        eb: *ErrorBundle.Wip,
    ) Allocator.Error!ErrorBundle.SourceLocationIndex {
        const tree = &file.tree.?;
        const start = tree.tokenStart(tok);
        const end = start + tree.tokenSlice(tok).len;
        const loc = std.zig.findLineColumn(file.source.?, start);
        return eb.addSourceLocation(.{
            .src_path = try eb.printString("{f}", .{file.path.fmt(comp)}),
            .span_start = start,
            .span_main = start,
            .span_end = @intCast(end),
            .line = @intCast(loc.line),
            .column = @intCast(loc.column),
            .source_line = try eb.addString(loc.source_line),
        });
    }
};

pub const Path = struct {
    root: Root,
    /// This path is always in a normalized form, where:
    /// * All components are separated by `fs.path.sep`
    /// * There are no repeated separators (like "foo//bar")
    /// * There are no "." or ".." components
    /// * There is no trailing path separator
    ///
    /// There is a leading separator iff `root` is `.none` *and* `builtin.target.os.tag != .wasi`.
    ///
    /// If this `Path` exactly represents a `Root`, the sub path is "", not ".".
    sub_path: []u8,

    const Root = enum {
        /// `sub_path` is relative to the Zig lib directory on `Compilation`.
        duni_lib,
        build_root,
        /// `sub_path` is not relative to any of the roots listed above.
        /// It is resolved starting with `Directories.cwd`; so it is an absolute path on most
        /// targets, but cwd-relative on WASI. We do not make it cwd-relative on other targets
        /// so that `Path.digest` gives hashes which can be stored in the Zig cache (as they
        /// don't depend on a specific compiler instance).
        none,
    };

    pub fn fromUnresolved(gpa: Allocator, unresolved_parts: []const []const u8) Allocator.Error!Path {
        const path_resolved = try Io.Dir.path.resolve(gpa, unresolved_parts);

        return .{ .root = .build_root, .sub_path = path_resolved };
    }

    /// Given a `Path`, returns the directory handle and sub path to be used to open the path.
    pub fn openInfo(p: Path) struct { Io.Dir, []const u8 } {
        const dir = switch (p.root) {
            .none => {
                unreachable;
                // const cwd_sub_path = absToCwdRelative(p.sub_path, dirs.cwd);
                // return .{ Io.Dir.cwd(), if (cwd_sub_path.len == 0) "." else cwd_sub_path };
            },
            .duni_lib => Io.Dir.cwd(),
            .build_root => Io.Dir.cwd(),
        };
        if (p.sub_path.len == 0) return .{ dir, "." };
        assert(!fs.path.isAbsolute(p.sub_path));
        return .{ dir, p.sub_path };
    }

    pub const format = unreachable; // do not format direcetly
    pub fn fmt(p: Path, comp: *Compilation) Formatter {
        return .{ .p = p, .comp = comp };
    }
    const Formatter = struct {
        p: Path,
        comp: *Compilation,
        pub fn format(f: Formatter, w: *Writer) Writer.Error!void {
            const root_path: []const u8 = switch (f.p.root) {
                .duni_lib => "",
                .build_root => "",
                .none => {
                    // try w.writeAll(absToCwdRelative(f.p.sub_path, f.comp.dirs.cwd));
                    return;
                },
            };
            try w.writeAll(root_path);
            if (f.p.sub_path.len > 0) {
                if (root_path.len != 0) try w.writeByte(fs.path.sep);
                try w.writeAll(f.p.sub_path);
            }
        }
    };

    pub fn deinit(p: Path, gpa: Allocator) void {
        gpa.free(p.sub_path);
    }
};

pub fn init(comp: *Compilation, gpa: Allocator, io: Io) !void {
    _ = io; // should be use by InternPool
    try comp.intern_pool.init(gpa);
}

pub fn compile(comp: *Compilation) !void {
    const gpa = comp.gpa;
    const file = comp.file;
    const io = comp.io;

    //TODO(tzelon): move to where we find deps
    const new_file_index = try comp.intern_pool.createFile(gpa, .{
        .file = file,
        .root_type = .none,
    });

    // TODO(move): to a different location
    // errdefer comptime unreachable; // because we don't remove the file from the internpool

    var source_file = f: {
        const dir, const sub_path = file.path.openInfo();
        break :f try dir.openFile(io, sub_path, .{});
    };
    defer source_file.close(io);

    const stat = try source_file.stat(io);

    const source = try gpa.allocSentinel(u8, @intCast(stat.size), 0);
    defer if (file.source == null) gpa.free(source);
    var source_fr = source_file.reader(io, &.{});
    source_fr.size = stat.size;
    source_fr.interface.readSliceAll(source) catch |err| switch (err) {
        error.ReadFailed => return source_fr.err.?,
        error.EndOfStream => return error.UnexpectedEndOfFile,
    };

    file.source = source;

    file.tree = try Ast.parse(gpa, source);

    file.dir = try AstGen.generate(gpa, file.tree.?);

    log.debug("AstGen fresh success: {f}", .{file.path.fmt(comp)});

    if (file.dir.?.hasCompileErrors()) {
        try comp.failed_files.putNoClobber(gpa, new_file_index, null);
    }
    if (file.dir.?.loweringFailed()) {
        file.status = .astgen_failure;
    } else {
        file.status = .success;
    }

    if (anyErrors(comp)) {
        // Skip flushing and keep source files loaded for error reporting.
        return;
    }
}

pub fn anyErrors(comp: *Compilation) bool {
    var errors = comp.getAllErrorsAlloc() catch return true;
    defer errors.deinit(comp.gpa);
    return errors.errorMessageCount() > 0;
}

pub fn getAllErrorsAlloc(comp: *Compilation) error{OutOfMemory}!ErrorBundle {
    const gpa = comp.gpa;
    var bundle: ErrorBundle.Wip = undefined;
    try bundle.init(gpa);
    defer bundle.deinit();

    if (comp.failed_files.count() != 0) {
        for (comp.failed_files.keys(), comp.failed_files.values()) |file_index, _| {
            const file = comp.intern_pool.filePtr(file_index);

            // AstGen succeeded with errors. Note that this may include AST errors.
            // Tree must be loaded.
            _ = file.getTree(comp) catch {
                // try unableToLoadZcuFile(zcu, &bundle, file, err);
                std.log.err("unable to load file", .{});
                continue;
            };
            const path = try std.fmt.allocPrint(gpa, "{f}", .{file.path.fmt(comp)});
            defer gpa.free(path);
            assert(file.dir != null);

            try bundle.addDirErrorMessages(file.dir.?, file.tree.?, file.source.?, path);
        }
    }

    return bundle.toOwnedBundle("");
}

pub fn deinit(comp: *Compilation) void {
    const gpa = comp.gpa;
    for (comp.failed_files.values()) |value| {
        if (value) |msg| gpa.free(msg);
    }

    // TODO(tzelon): we should have a list of loaded files (import_table in zig) to destroy all files
    for (comp.failed_files.keys()) |file_index| {
        comp.destroyFile(file_index);
    }

    comp.failed_files.deinit(gpa);

    comp.intern_pool.deinit(gpa);
}

fn deinitFile(comp: *Compilation, file_index: Compilation.File.Index) void {
    const gpa = comp.gpa;
    const file = comp.intern_pool.filePtr(file_index);
    log.debug("deinit File {f}", .{file.path.fmt(comp)});
    file.path.deinit(gpa);
    file.unload(gpa);
    file.* = undefined;
}

fn destroyFile(comp: *Compilation, file_index: Compilation.File.Index) void {
    const gpa = comp.gpa;
    const file = comp.intern_pool.filePtr(file_index);
    deinitFile(comp, file_index);
    gpa.destroy(file);
}
