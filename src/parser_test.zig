//! Tests for the parser. The parser is not constructed directly — it is
//! scratch state built inside `Ast.parse` — so these tests drive it through
//! `Ast.parse(gpa, source)` and assert on the resulting tree.
//!
//! Note: `Ast.parse` only fails on OOM. Parse errors (recoverable *and* fatal)
//! are collected into `tree.errors`, so error tests assert on that slice.
//! Expressions only parse inside `fn` bodies, so inputs are full declarations.

const std = @import("std");
const Ast = @import("ast.zig");
const ErrorTag = Ast.Error.Tag;

const gpa = std.testing.allocator;

/// Assert `source` parses with no recoverable errors.
fn expectOk(source: [:0]const u8) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) {
        std.debug.print("unexpected errors:\n", .{});
        for (tree.errors) |e| std.debug.print("  {s}\n", .{@tagName(e.tag)});
        return error.UnexpectedParseError;
    }
}

/// Assert `source` produces exactly `expected` recoverable errors, in order.
fn expectErrors(source: [:0]const u8, expected: []const ErrorTag) !void {
    var tree = try Ast.parse(gpa, source);
    defer tree.deinit(gpa);

    std.testing.expectEqual(expected.len, tree.errors.len) catch |err| {
        std.debug.print("errors found:\n", .{});
        for (tree.errors) |e| std.debug.print("  {s}\n", .{@tagName(e.tag)});
        return err;
    };
    for (expected, tree.errors) |want, got| {
        try std.testing.expectEqual(want, got.tag);
    }
}

test "ok: function with assignments" {
    try expectOk(
        \\fn add(x: int, y: int): int {
        \\  x = 2
        \\  y = 4
        \\}
    );
}

test "ok: arithmetic precedence" {
    try expectOk(
        \\fn main(): int {
        \\  z = 1 + 2 * 3
        \\}
    );
}

test "ok: grouped and unary expressions" {
    try expectOk(
        \\fn main(): int {
        \\  z = -(1 + 2)
        \\}
    );
}

// The trailing `.expected_return_type` in the error cases below is the
// recovery cascade: once the in-body error aborts the declaration, the leftover
// `}` is re-scanned at container level and hits the catch-all `else` branch in
// `parseContainerMembers`. Pinning it documents current behavior; tighten these
// once container-level recovery resyncs past stray tokens.

test "error: missing expression after operator" {
    try expectErrors(
        \\fn main(): int {
        \\  z = 4 +
        \\}
    , &.{ .expected_expression, .expected_return_type });
}

test "error: unclosed grouping" {
    try expectErrors(
        \\fn main(): int {
        \\  z = (4 + 2
        \\}
    , &.{ .expected_token, .expected_return_type });
}
