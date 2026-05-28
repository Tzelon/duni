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

test "error: missing expression after operator" {
    try expectErrors(
        \\fn main(): int {
        \\  z = 4 +
        \\}
    , &.{.expected_expression});
}

test "error: unclosed grouping" {
    try expectErrors(
        \\fn main(): int {
        \\  z = (4 + 2
        \\}
    , &.{.expected_token});
}

test "ok: bare identifier statement" {
    try expectOk(
        \\fn main(): int {
        \\  x
        \\}
    );
}

test "ok: call with no arguments" {
    try expectOk(
        \\fn main(): int {
        \\  foo()
        \\}
    );
}

test "ok: call with multiple argument expressions" {
    try expectOk(
        \\fn add(x: int, y: int): int {
        \\  foo(x, 5 + 2, y * 3)
        \\}
    );
}

test "ok: call inside binary expression" {
    try expectOk(
        \\fn main(): int {
        \\  a + foo()
        \\}
    );
}

test "ok: chained call on call result" {
    try expectOk(
        \\fn main(): int {
        \\  f()(x)
        \\}
    );
}

test "ok: nested call as argument" {
    try expectOk(
        \\fn main(): int {
        \\  f(g())
        \\}
    );
}

test "ok: assignment of call result" {
    try expectOk(
        \\fn main(): int {
        \\  z = foo(1, 2)
        \\}
    );
}

test "error: missing comma between arguments" {
    try expectErrors(
        \\fn main(): int {
        \\  foo(1 2)
        \\}
    , &.{.expected_comma_after_arg});
}

test "error: unclosed call argument list" {
    try expectErrors(
        \\fn main(): int {
        \\  foo(1, 2
        \\}
    , &.{ .expected_comma_after_arg, .expected_expression });
}

test "error: missing argument after comma" {
    try expectErrors(
        \\fn main(): int {
        \\  foo(1,)
        \\}
    , &.{.expected_expression});
}
