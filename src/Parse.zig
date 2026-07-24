//! Represents in-progress parsing, will be converted to an Ast after completion.

const Parse = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Token = @import("./scanner.zig").Token;

const Ast = @import("./Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const NullTerminatedString = @import("string.zig").NullTerminatedString;

const log = std.log.scoped(.parser);

pub const Error = error{ParseError} || Allocator.Error;

gpa: Allocator,
/// source text
source: [:0]const u8,

// scanner tokens
tokens: Ast.TokenList.Slice,
/// current token index
token_index: TokenIndex,

/// list of AST nodes
nodes: std.MultiArrayList(Node),
/// extra data referenced by AST node. example: function params
extra_data: std.ArrayList(u32),
/// list of recoverable errors
errors: std.ArrayList(Ast.Error),

/// temp array of nodes
scratch: std.ArrayList(Node.Index),

pub fn parseRoot(p: *Parse) !void {
    // Root node must be index 0.
    p.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    const span = try p.parseBlock();
    p.nodes.items(.data)[0] = .{ .extra_range = span };
}

/// Statement-level resync: skip to just past the next newline (or stop at eof).
fn findNextStmt(p: *Parse) void {
    while (true) switch (p.current()) {
        .newline => {
            _ = p.advance();
            return;
        },
        .eof => return,
        else => _ = p.advance(),
    };
}

fn expression(p: *Parse) !Node.Index {
    return p.parsePrecedence(.prec_assignment);
}

fn parseBlock(p: *Parse) !Node.SubRange {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        while (p.check(.newline)) _ = p.advance(); // blank lines / separators
        if (p.check(.eof) or p.check(.r_brace)) break;

        const stmt = p.expression() catch |err| switch (err) {
            error.ParseError => {
                p.findNextStmt();
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try p.scratch.append(p.gpa, stmt);

        if (!p.check(.newline) and !p.check(.eof)) {
            try p.warnExpected(.newline);
            p.findNextStmt();
        }
    }

    const span = try p.listToSpan(p.scratch.items[scratch_top..]);
    return span;
}

// Pratt Parsing
fn parsePrecedence(p: *Parse, precedence: Precedence) !Node.Index {
    const prefixRule = p.getRule(p.current()).prefix orelse {
        // no expression starting here
        return p.failMsg(.{
            .tag = .expected_expression,
            .token = p.token_index,
        });
    };

    var node = try prefixRule(p);

    while (@intFromEnum(precedence) <= @intFromEnum(p.getRule(p.current()).precedence)) {
        const infixRule = p.getRule(p.current()).infix orelse {
            try p.warn(.expected_expression);
            return node;
        };

        node = try infixRule(p, node);
    }

    return node;
}

/// take a list of Node.Index an return SubRange to extra_data
fn listToSpan(p: *Parse, list: []const Node.Index) Allocator.Error!Node.SubRange {
    try p.extra_data.appendSlice(p.gpa, @ptrCast(list));

    return .{
        .start = @enumFromInt(p.extra_data.items.len - list.len),
        .end = @enumFromInt(p.extra_data.items.len),
    };
}

/// append extra data to the extra_data list, can be any struct
fn addExtra(p: *Parse, extra: anytype) Allocator.Error!Node.ExtraIndex {
    const fields = std.meta.fields(@TypeOf(extra));
    try p.extra_data.ensureUnusedCapacity(p.gpa, fields.len);
    const result: Node.ExtraIndex = @enumFromInt(p.extra_data.items.len);
    inline for (fields) |field| {
        const data: u32 = switch (field.type) {
            Node.Index,
            // Node.OptionalIndex,
            // OptionalTokenIndex,
            Node.ExtraIndex,
            => @intFromEnum(@field(extra, field.name)),
            TokenIndex,
            => @field(extra, field.name),
            else => @compileError("unexpected field type"),
        };
        p.extra_data.appendAssumeCapacity(data);
    }
    return result;
}

fn getRule(self: *Parse, tag: Token.Tag) ParseRule {
    _ = self;
    const rule = switch (tag) {
        .l_paren => comptime ParseRule.init(Parse.grouping, null, .prec_call),
        .r_paren => comptime ParseRule.init(null, null, .prec_none),
        .l_brace => comptime ParseRule.init(Parse.block, null, .prec_none),
        .r_brace => comptime ParseRule.init(null, null, .prec_none),
        .minus => comptime ParseRule.init(Parse.unary, Parse.binary, .prec_term),
        .plus => comptime ParseRule.init(null, Parse.binary, .prec_term),
        .star => comptime ParseRule.init(null, Parse.binary, .prec_factor),
        .slash => comptime ParseRule.init(null, Parse.binary, .prec_factor),
        .equal => comptime ParseRule.init(null, Parse.bind, .prec_assignment),
        // .equal_equal => comptime ParseRule.init(null, Parse.binary, .prec_equality),
        .string_literal => comptime ParseRule.init(Parse.string, null, .prec_none),
        .number_literal => comptime ParseRule.init(Parse.number, null, .prec_none),
        .identifier => comptime ParseRule.init(Parse.identifier, null, .prec_none),
        .eof => comptime ParseRule.init(null, null, .prec_none),
        .newline => comptime ParseRule.init(null, null, .prec_none),
        else => {
            log.err("no rule for token {}", .{tag});
            unreachable;
        },
    };

    return rule;
}

/// example: x
fn identifier(p: *Parse) !Node.Index {
    return p.addNode(.{
        .tag = .identifier,
        .main_token = p.advance(),
        .data = undefined,
    });
}

/// example: 47
fn number(p: *Parse) !Node.Index {
    return p.addNode(.{
        .tag = .number_literal,
        .main_token = p.advance(),
        .data = undefined,
    });
}

/// example: "hello world"
fn string(p: *Parse) !Node.Index {
    return p.addNode(.{
        .tag = .string_literal,
        .main_token = p.advance(),
        .data = undefined,
    });
}

/// example: -1
fn unary(p: *Parse) !Node.Index {
    const op_nts: NullTerminatedString = switch (p.current()) {
        .minus => .minus,
        else => unreachable,
    };

    const main_token = p.advance();
    const operand = try p.parsePrecedence(.prec_unary);

    const span = try p.listToSpan(&.{operand});
    const args = try p.addExtra(span);

    return p.addNode(.{ .tag = .form, .main_token = main_token, .data = .{ .form = .{ .op = op_nts, .args = args } } });
}

/// example: 1 + 1
fn binary(p: *Parse, lhs: Node.Index) !Node.Index {
    const op_nts: NullTerminatedString = switch (p.current()) {
        .plus => .plus,
        .minus => .minus,
        .star => .star,
        .slash => .slash,
        else => unreachable,
    };

    const rule = p.getRule(p.current());
    const main_token = p.advance();
    // We use one higher level of precedence for the right operand because the binary operators are left-associative.
    const rhs = try p.parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

    const span = try p.listToSpan(&.{ lhs, rhs });
    const args = try p.addExtra(span);

    return p.addNode(.{
        .tag = .form,
        .main_token = main_token,
        .data = .{ .form = .{ .op = op_nts, .args = args } },
    });
}

fn block(p: *Parse) !Node.Index {
    const main_token = p.advance();
    const span = try p.parseBlock();
    const args = try p.addExtra(span);
    _ = try p.consume(.r_brace);

    return p.addNode(.{ .tag = .form, .main_token = main_token, .data = .{ .form = .{ .op = .block, .args = args } } });
}

fn grouping(p: *Parse) !Node.Index {
    _ = p.advance();
    const inner = try p.expression();
    _ = try p.consume(.r_paren);

    return inner;
}

// example: x = 1
fn bind(p: *Parse, lhs: Node.Index) !Node.Index {
    const main_token = p.advance();
    // Same precedence for the right operand (no +1 like `binary`) because
    // `=` is right-associative: `a = b = c` parses as `a = (b = c)`.
    const rhs = try p.parsePrecedence(.prec_assignment);

    const span = try p.listToSpan(&.{ lhs, rhs });
    const args = try p.addExtra(span);

    return p.addNode(.{ .tag = .form, .main_token = main_token, .data = .{ .form = .{ .op = .equal, .args = args } } });
}

const ParsePrefixFn = *const fn (parser: *Parse) Error!Node.Index;
const ParseInfixFn = *const fn (parser: *Parse, lhs: Node.Index) Error!Node.Index;

const ParseRule = struct {
    prefix: ?ParsePrefixFn,
    infix: ?ParseInfixFn,
    precedence: Precedence,

    pub fn init(prefix: ?ParsePrefixFn, infix: ?ParseInfixFn, precedence: Precedence) ParseRule {
        return ParseRule{ .prefix = prefix, .infix = infix, .precedence = precedence };
    }
};

const Precedence = enum {
    prec_none,
    prec_assignment, // =
    prec_or, // or
    prec_and, // and
    prec_equality, // == !=
    prec_comparison, // < > <= >=
    prec_term, // + -
    prec_factor, // * /
    prec_unary, // ! -
    prec_call, // . ()
    prec_primary,
};

// Helpers nodes
fn addNode(p: *Parse, elem: Ast.Node) Allocator.Error!Node.Index {
    const result: Node.Index = @enumFromInt(p.nodes.len);
    try p.nodes.append(p.gpa, elem);
    return result;
}

// Helpers tokens
fn tokenTag(p: *const Parse, token_index: TokenIndex) Token.Tag {
    return p.tokens.items(.tag)[token_index];
}

fn tokenStart(p: *const Parse, token_index: TokenIndex) Ast.ByteOffset {
    return p.tokens.items(.start)[token_index];
}

fn tokensOnSameLine(p: *Parse, token1: TokenIndex, token2: TokenIndex) bool {
    return std.mem.findScalar(u8, p.source[p.tokenStart(token1)..p.tokenStart(token2)], '\n') == null;
}

/// return the current token in the sequence. without **advancing**
fn current(p: *Parse) Token.Tag {
    return p.tokens.items(.tag)[p.token_index];
}

/// return the current token position and move to the next
fn advance(p: *Parse) TokenIndex {
    const result = p.token_index;
    p.token_index += 1;
    return result;
}

/// return true if the current token has the given tag
fn check(p: *Parse, expected_tag: Token.Tag) bool {
    return p.tokens.items(.tag)[p.token_index] == expected_tag;
}

/// consume the current token only if the current token matches the type
fn consume(p: *Parse, expected_tag: Token.Tag) !TokenIndex {
    if (!p.check(expected_tag)) {
        log.err("failed to consume {}\n", .{expected_tag});
        return p.failExpected(expected_tag);
    }

    return p.advance();
}

// Helpers messages
fn warnExpected(p: *Parse, expected_token: Token.Tag) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.warnMsg(.{
        .tag = .expected_token,
        .token = p.token_index,
        .extra = .{ .expected_tag = expected_token },
    });
}

fn warnMsg(p: *Parse, msg: Ast.Error) error{OutOfMemory}!void {
    @branchHint(.cold);

    switch (msg.tag) {
        .expected_token => if (msg.token != 0 and !p.tokensOnSameLine(msg.token - 1, msg.token)) {
            var copy = msg;
            copy.token_is_prev = true;
            copy.token -= 1;
            return p.errors.append(p.gpa, copy);
        },
        else => {},
    }
    try p.errors.append(p.gpa, msg);
}

fn warn(p: *Parse, error_tag: Ast.Error.Tag) error{OutOfMemory}!void {
    @branchHint(.cold);
    try p.warnMsg(.{ .tag = error_tag, .token = p.token_index });
}

fn failMsg(p: *Parse, msg: Ast.Error) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    try p.warnMsg(msg);
    return error.ParseError;
}

fn failExpected(p: *Parse, expected_token: Token.Tag) error{ ParseError, OutOfMemory } {
    @branchHint(.cold);
    return p.failMsg(.{
        .tag = .expected_token,
        .token = p.token_index,
        .extra = .{ .expected_tag = expected_token },
    });
}
