//! Data-driven compiler test harness (see test_plan.md §5).
//!
//! Walks `test/cases/` and builds one chain of build steps per `.duni` case
//! file. A case file is the whole test: the program at the top, the expected
//! result in a trailing `//` comment block (the footer). Subdirectories carry
//! no meaning to the harness beyond the case name prefix.
//!
//! Directives:
//!   // wat            — run the compiler, compare stdout to the golden WAT
//!                       (exact match). Golden lines follow a bare `//`
//!                       separator line, each prefixed `// `.
//!   // run            — compile, assemble with wat2wasm, execute with
//!                       node + host.js, compare stdout. Each
//!                       `// expect_stdout=<text>` line expects `<text>\n`.
//!   // error          — the compiler must exit 1 and print exactly these
//!                       diagnostics to stderr (same footer shape as `wat`).
//!                       The compiler's input path is stripped from stderr
//!                       before comparing, so expected lines read `:1:1: ...`.
//!
//! Duni has no comment syntax, so the footer is harness metadata only: the
//! compiler is given a copy of the file with the footer stripped.

const std = @import("std");

pub const Options = struct {
    duni_exe: *std.Build.Step.Compile,
    /// Only build cases whose name contains this substring.
    test_filter: ?[]const u8,
    /// Paths to the external tools `// run` cases need. When either is null,
    /// run cases are skipped and the skip count is logged.
    wat2wasm: ?[]const u8,
    node: ?[]const u8,
};

pub fn addCases(b: *std.Build, step: *std.Build.Step, options: Options) !void {
    const io = b.graph.io;
    const arena = b.allocator;

    var cases_dir = b.build_root.handle.openDir(io, "test/cases", .{ .iterate = true }) catch |err| {
        std.debug.print("test/cases.zig: unable to open test/cases: {t}\n", .{err});
        return err;
    };
    defer cases_dir.close(io);

    var skipped_run_cases: usize = 0;

    var walker = try cases_dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".duni")) continue;

        const case_name = try arena.dupe(u8, entry.path[0 .. entry.path.len - ".duni".len]);
        if (options.test_filter) |filter| {
            if (std.mem.indexOf(u8, case_name, filter) == null) continue;
        }

        const source = try cases_dir.readFileAlloc(io, entry.path, arena, .unlimited);
        const case = Case.parse(arena, source) catch |err| {
            std.debug.print("test/cases/{s}: bad case file: {t}\n", .{ entry.path, err });
            return err;
        };

        // The compiler must not see the footer — give it a stripped copy.
        const stripped_source = b.addWriteFiles().add(entry.basename, case.program);

        switch (case.directive) {
            .wat => {
                const compile = runCompiler(b, options.duni_exe, case_name, stripped_source);
                compile.expectStdOutEqual(case.expected);
                step.dependOn(ReportStep.create(b, case_name, &compile.step));
            },
            .@"error" => {
                const check = DiagnosticsStep.create(b, case_name, .{
                    .exe = options.duni_exe.getEmittedBin(),
                    .source_file = stripped_source,
                    .expected = case.expected,
                });
                step.dependOn(ReportStep.create(b, case_name, check));
            },
            .run => {
                const wat2wasm_path = options.wat2wasm orelse {
                    skipped_run_cases += 1;
                    continue;
                };
                const node_path = options.node orelse {
                    skipped_run_cases += 1;
                    continue;
                };

                const compile = runCompiler(b, options.duni_exe, case_name, stripped_source);
                const wat = compile.captureStdOut(.{ .basename = "case.wat" });

                const assemble = b.addSystemCommand(&.{wat2wasm_path});
                assemble.setName(b.fmt("wat2wasm {s}", .{case_name}));
                assemble.addFileArg(wat);
                assemble.addArg("-o");
                const wasm = assemble.addOutputFileArg("case.wasm");

                const execute = b.addSystemCommand(&.{node_path});
                execute.setName(b.fmt("run {s}", .{case_name}));
                execute.addFileArg(b.path("host.js"));
                execute.addFileArg(wasm);
                execute.expectStdOutEqual(case.expected);
                step.dependOn(ReportStep.create(b, case_name, &execute.step));
            },
        }
    }

    if (skipped_run_cases != 0) {
        std.debug.print(
            "test-cases: skipped {d} `// run` case(s); pass -Dwat2wasm=<path> and -Dnode=<path> (or install the tools) to run them\n",
            .{skipped_run_cases},
        );
    }
}

fn runCompiler(
    b: *std.Build,
    duni_exe: *std.Build.Step.Compile,
    case_name: []const u8,
    source_file: std.Build.LazyPath,
) *std.Build.Step.Run {
    const compile = b.addRunArtifact(duni_exe);
    compile.setName(b.fmt("duni {s}", .{case_name}));
    compile.addFileArg(source_file);
    return compile;
}

/// Runs the compiler on an `// error` case and asserts both that it exited 1
/// and that its stderr matches the case's expected diagnostics byte for byte,
/// after stripping the compiler's input path (a machine-specific cache path)
/// so case files stay portable.
///
/// This spawns the child itself rather than checking a `std.Build.Step.Run`.
/// A failed check inside `Run` aborts the chain before any dependent step
/// gets to look at the output, and its message for a wrong exit status is just
/// `process exited with code N` — the captured stderr is written to a file in
/// the cache and never shown. Owning the spawn means one failure message can
/// carry the exit status and the diagnostics together, which is what you
/// actually need to tell "the compiler said the wrong thing" apart from "the
/// compiler said nothing at all".
const DiagnosticsStep = struct {
    step: std.Build.Step,
    exe: std.Build.LazyPath,
    source_file: std.Build.LazyPath,
    expected: []const u8,

    const CaseInfo = struct {
        exe: std.Build.LazyPath,
        source_file: std.Build.LazyPath,
        expected: []const u8,
    };

    fn create(b: *std.Build, case_name: []const u8, case: CaseInfo) *std.Build.Step {
        const diagnostics = b.allocator.create(DiagnosticsStep) catch @panic("OOM");
        diagnostics.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("check diagnostics {s}", .{case_name}),
                .owner = b,
                .makeFn = make,
            }),
            .exe = case.exe.dupe(b),
            .source_file = case.source_file.dupe(b),
            .expected = case.expected,
        };
        diagnostics.exe.addStepDependencies(&diagnostics.step);
        diagnostics.source_file.addStepDependencies(&diagnostics.step);
        return &diagnostics.step;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        const b = step.owner;
        const diagnostics: *DiagnosticsStep = @fieldParentPtr("step", step);
        try step.singleUnchangingWatchInput(diagnostics.source_file);

        const exe_path = diagnostics.exe.getPath2(b, step);
        const source_path = diagnostics.source_file.getPath2(b, step);

        const result = try step.captureChildProcess(
            options.gpa,
            options.progress_node,
            &.{ exe_path, source_path },
        );
        // The compiler is expected to write to stderr — that output is this
        // step's input, not a report that the child misbehaved. Drop what
        // `captureChildProcess` queued so a passing case stays quiet and a
        // failing one shows the output once, inside the diff below.
        step.result_error_msgs.clearRetainingCapacity();

        const found = try std.mem.replaceOwned(u8, b.allocator, result.stderr, source_path, "");
        const exit_ok = switch (result.term) {
            .exited => |code| code == 1,
            else => false,
        };
        if (exit_ok and std.mem.eql(u8, diagnostics.expected, found)) return;

        // Only call out the exit status when it is the thing that went wrong;
        // for a plain text mismatch the diff below is the whole story.
        const term_line = if (exit_ok) "" else b.fmt(
            "========= the compiler {s}, expected exit code 1\n",
            .{describeTerm(b, result.term)},
        );

        return step.fail(
            \\
            \\{s}========= expected diagnostics: =========
            \\{s}========= but found: ====================
            \\{s}=========================================
        , .{ term_line, diagnostics.expected, if (found.len == 0) "(nothing on stderr)\n" else found });
    }

    fn describeTerm(b: *std.Build, term: std.process.Child.Term) []const u8 {
        return switch (term) {
            .exited => |code| b.fmt("exited with code {d}", .{code}),
            .signal => |signal| b.fmt("terminated with signal {d}", .{signal}),
            .stopped => |signal| b.fmt("stopped with signal {d}", .{signal}),
            .unknown => |code| b.fmt("terminated unexpectedly ({d})", .{code}),
        };
    }
};

/// Prints `✓ <case name>` once the case's final step has succeeded. A failed
/// case never reaches its report step; the build runner already prints the
/// failing step's name and an expected/found diff.
const ReportStep = struct {
    step: std.Build.Step,
    case_name: []const u8,

    fn create(b: *std.Build, case_name: []const u8, after: *std.Build.Step) *std.Build.Step {
        const report = b.allocator.create(ReportStep) catch @panic("OOM");
        report.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = b.fmt("report {s}", .{case_name}),
                .owner = b,
                .makeFn = make,
            }),
            .case_name = case_name,
        };
        report.step.dependOn(after);
        return &report.step;
    }

    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) anyerror!void {
        _ = options;
        const report: *ReportStep = @fieldParentPtr("step", step);
        std.debug.print("✓ {s}\n", .{report.case_name});
    }
};

const Case = struct {
    /// The Duni program: everything above the footer.
    program: []const u8,
    directive: Directive,
    /// The exact expected stdout (of the compiler for .wat, of the executed
    /// program for .run), including the trailing newline.
    expected: []const u8,

    const Directive = enum { wat, run, @"error" };

    const ParseError = error{
        MissingFooter,
        UnknownDirective,
        MissingSeparator,
        MalformedFooterLine,
        MissingExpectation,
        OutOfMemory,
    };

    fn parse(arena: std.mem.Allocator, source: []const u8) ParseError!Case {
        // The footer is the trailing run of lines that all start with `//`.
        var footer_start: ?usize = null;
        var offset: usize = 0;
        var line_it = std.mem.splitScalar(u8, source, '\n');
        while (line_it.next()) |line| {
            const line_offset = offset;
            offset += line.len + 1;
            // A terminal newline produces one empty trailing slice; it is not
            // a line of the file.
            if (line_offset == source.len) break;
            if (std.mem.startsWith(u8, line, "//")) {
                if (footer_start == null) footer_start = line_offset;
            } else {
                footer_start = null;
            }
        }
        const footer = source[footer_start orelse return error.MissingFooter ..];
        const program = source[0 .. footer_start orelse unreachable];

        var footer_it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, footer, "\n"), '\n');
        const directive_line = footer_it.next() orelse return error.MissingFooter;
        const directive = std.meta.stringToEnum(Directive, try stripCommentPrefix(directive_line)) orelse
            return error.UnknownDirective;

        switch (directive) {
            .wat, .@"error" => {
                // The directive, a bare `//` separator, then the golden output
                // (WAT on stdout for `wat`, diagnostics on stderr for `error`).
                const separator = footer_it.next() orelse return error.MissingSeparator;
                if (!std.mem.eql(u8, separator, "//")) return error.MissingSeparator;

                var expected: std.ArrayList(u8) = .empty;
                var has_lines = false;
                while (footer_it.next()) |line| {
                    has_lines = true;
                    try expected.appendSlice(arena, try stripCommentPrefix(line));
                    try expected.append(arena, '\n');
                }
                if (!has_lines) return error.MissingExpectation;
                return .{ .program = program, .directive = directive, .expected = expected.items };
            },
            .run => {
                // `// run`, then one `// expect_stdout=<text>` per expected line.
                var expected: std.ArrayList(u8) = .empty;
                var has_lines = false;
                while (footer_it.next()) |line| {
                    has_lines = true;
                    const content = try stripCommentPrefix(line);
                    const value = std.mem.cutPrefix(u8, content, "expect_stdout=") orelse
                        return error.MalformedFooterLine;
                    try expected.appendSlice(arena, value);
                    try expected.append(arena, '\n');
                }
                if (!has_lines) return error.MissingExpectation;
                return .{ .program = program, .directive = directive, .expected = expected.items };
            },
        }
    }

    /// `//` is an empty content line; `// x` is the content `x`. Anything
    /// else (`//x`, trailing-whitespace-only `// `) is malformed.
    fn stripCommentPrefix(line: []const u8) error{MalformedFooterLine}![]const u8 {
        if (std.mem.eql(u8, line, "//")) return "";
        if (std.mem.startsWith(u8, line, "// ")) return line[3..];
        return error.MalformedFooterLine;
    }
};
