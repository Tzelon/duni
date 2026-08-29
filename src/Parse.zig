//! Represents in-progress parsing, will be converted to an Ast after completion.

const Parse = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const scan = @import("scanner.zig");
const Scanner = scan.Scanner;
const Token = scan.Token;

const Ast = @import("./Ast.zig");
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

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

/// Expression nesting depth — how many `parsePrecedence` frames are on the
/// stack. Bounded so pathological input (a thousand parens) reports an error
/// instead of overflowing the native stack.
nesting: u32 = 0,

const max_nesting = 256;

pub fn parseRoot(p: *Parse) Error!void {
    // Root node must be index 0.
    p.nodes.appendAssumeCapacity(.{
        .tag = .root,
        .main_token = 0,
        .data = undefined,
    });

    const span = try p.parseBlock(.root);
    p.nodes.items(.data)[0] = .{ .extra_range = span };
}

/// Statement-level resync: skip to just past the next newline (or stop at
/// eof). Braces opened after the failure point belong to the broken
/// construct and are skipped as a unit — only an *enclosing* `}` (depth 0)
/// stops the resync, unconsumed, so a block terminator is never eaten.
fn findNextStmt(p: *Parse) void {
    var brace_depth: u32 = 0;
    while (true) switch (p.current()) {
        .newline => {
            _ = p.advance();
            if (brace_depth == 0) return;
        },
        .l_brace => {
            brace_depth += 1;
            _ = p.advance();
        },
        .r_brace => {
            if (brace_depth == 0) return;
            brace_depth -= 1;
            _ = p.advance();
        },
        .eof => return,
        else => _ = p.advance(),
    };
}

fn expression(p: *Parse) !Node.Index {
    return p.parsePrecedence(.prec_assignment);
}

fn parseBlock(p: *Parse, comptime context: enum { root, brace_block }) !Node.SubRange {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        while (p.check(.newline)) _ = p.advance(); // blank lines / separators
        if (p.check(.eof)) break;
        if (p.check(.r_brace)) {
            // Inside braces this is the terminator; at the root it is a
            // stray — report it, skip it, keep parsing statements.
            if (context == .brace_block) break;
            try p.warnMsg(.{ .tag = .expected_expression, .token = p.token_index });
            _ = p.advance();
            continue;
        }

        const stmt = p.expression() catch |err| switch (err) {
            error.ParseError => {
                p.findNextStmt();
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try p.scratch.append(p.gpa, stmt);

        if (!p.check(.newline) and !p.check(.eof) and !p.check(.r_brace)) {
            try p.warnExpected(.newline);
            p.findNextStmt();
        }
    }

    const span = try p.listToSpan(p.scratch.items[scratch_top..]);
    return span;
}

fn parseProto(p: *Parse, fn_token: TokenIndex) !Node.Index {
    _ = try p.consume(.identifier); // the fn name, always at fn_token + 1

    const params = try p.parseParams();
    // consume r_paren here so we can store it in the node
    const r_paren = try p.consume(.r_paren);

    const return_type: Node.OptionalIndex = if (try p.parseTypeExpr()) |type_node|
        type_node.toOptional()
    else blk: {
        // Point at the token before the cursor (the closing paren) — that is
        // where the return type was expected.
        try p.warnMsg(.{ .tag = .expected_return_type, .token = p.token_index, .token_is_prev = true });
        break :blk .none;
    };

    const params_index = try p.addExtra(Node.FnProto{
        .rparen = r_paren,
        .params_start = params.start,
        .params_end = params.end,
    });

    return p.addNode(.{
        .tag = .fn_proto,
        .main_token = fn_token,
        .data = .{ .extra_and_opt_node = .{ params_index, return_type } },
    });
}

fn parseParams(p: *Parse) !Node.SubRange {
    _ = try p.consume(.l_paren);

    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);

    while (true) {
        if (p.check(.r_paren)) break;
        const param = try p.parseParamDecl();
        try p.scratch.append(p.gpa, param);

        if (!p.check(.comma)) break;
        _ = p.advance();
    }

    return p.listToSpan(p.scratch.items[scratch_top..]);
}

/// A parameter is `name type`. Only the type expression gets a node; the
/// name is the token before the type's first token.
fn parseParamDecl(p: *Parse) !Node.Index {
    _ = try p.consume(.identifier);
    return try p.parseTypeExpr() orelse return p.failMsg(.{ .tag = .expected_type_expr, .token = p.token_index });
}

fn parseTypeExpr(p: *Parse) !?Node.Index {
    switch (p.tokenTag(p.token_index)) {
        .identifier => {
            return try p.addNode(.{
                .tag = .identifier,
                .main_token = p.advance(),
                .data = undefined,
            });
        },
        else => return null,
    }
}

// Pratt Parsing
fn parsePrecedence(p: *Parse, precedence: Precedence) !Node.Index {
    if (p.nesting == max_nesting) {
        return p.failMsg(.{
            .tag = .expression_nested_too_deeply,
            .token = p.token_index,
        });
    }
    p.nesting += 1;
    defer p.nesting -= 1;

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

    // An invalid token can neither continue nor end an expression — report
    // it here rather than letting a statement terminator blame a missing
    // newline (the recoverable expected-expression path for `.invalid`).
    if (p.check(.invalid)) {
        return p.failMsg(.{ .tag = .expected_expression, .token = p.token_index });
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
        .keyword_fn => comptime ParseRule.init(Parse.function, null, .prec_none),
        .keyword_extern => comptime ParseRule.init(Parse.externFunction, null, .prec_none),
        .l_paren => comptime ParseRule.init(Parse.grouping, Parse.call, .prec_call),
        .r_paren => comptime ParseRule.init(null, null, .prec_none),
        .l_brace => comptime ParseRule.init(Parse.block, null, .prec_none),
        .r_brace => comptime ParseRule.init(null, null, .prec_none),
        .minus => comptime ParseRule.init(Parse.unary, Parse.binary, .prec_term),
        .plus => comptime ParseRule.init(null, Parse.binary, .prec_term),
        .star => comptime ParseRule.init(null, Parse.binary, .prec_factor),
        .slash => comptime ParseRule.init(null, Parse.binary, .prec_factor),
        .equal => comptime ParseRule.init(null, Parse.bind, .prec_assignment),
        .equal_equal => comptime ParseRule.init(null, Parse.binary, .prec_equality),
        .bang_equal => comptime ParseRule.init(null, Parse.binary, .prec_equality),
        .angle_left => comptime ParseRule.init(null, Parse.binary, .prec_comparison),
        .angle_left_equal => comptime ParseRule.init(null, Parse.binary, .prec_comparison),
        .angle_right => comptime ParseRule.init(null, Parse.binary, .prec_comparison),
        .angle_right_equal => comptime ParseRule.init(null, Parse.binary, .prec_comparison),
        .keyword_and => comptime ParseRule.init(null, Parse.binary, .prec_and),
        .keyword_or => comptime ParseRule.init(null, Parse.binary, .prec_or),
        .bang => comptime ParseRule.init(Parse.unary, null, .prec_none),
        .keyword_true => comptime ParseRule.init(Parse.boolLiteral, null, .prec_none),
        .keyword_false => comptime ParseRule.init(Parse.boolLiteral, null, .prec_none),
        .keyword_if => comptime ParseRule.init(Parse.ifExpr, null, .prec_none),
        .keyword_else => comptime ParseRule.init(null, null, .prec_none),
        .string_literal => comptime ParseRule.init(Parse.string, null, .prec_none),
        .number_literal => comptime ParseRule.init(Parse.number, null, .prec_none),
        .identifier => comptime ParseRule.init(Parse.identifier, null, .prec_none),
        .eof => comptime ParseRule.init(null, null, .prec_none),
        .newline => comptime ParseRule.init(null, null, .prec_none),
        .comma => comptime ParseRule.init(null, null, .prec_none),
        .invalid => comptime ParseRule.init(null, null, .prec_none),
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

/// example: true
fn boolLiteral(p: *Parse) !Node.Index {
    return p.addNode(.{
        .tag = .bool_literal,
        .main_token = p.advance(),
        .data = undefined,
    });
}

/// example: -1
fn unary(p: *Parse) !Node.Index {
    const tag: Node.Tag = switch (p.current()) {
        .minus => .negation,
        .bang => .bool_not,
        else => unreachable,
    };

    const main_token = p.advance();
    const operand = try p.parsePrecedence(.prec_unary);

    return p.addNode(.{ .tag = tag, .main_token = main_token, .data = .{ .node = operand } });
}

/// example: 1 + 1
fn binary(p: *Parse, lhs: Node.Index) !Node.Index {
    const tag: Node.Tag = switch (p.current()) {
        .plus => .add,
        .minus => .sub,
        .star => .mul,
        .slash => .div,
        .equal_equal => .equal_equal,
        .bang_equal => .bang_equal,
        .angle_left => .less_than,
        .angle_left_equal => .less_or_equal,
        .angle_right => .greater_than,
        .angle_right_equal => .greater_or_equal,
        .keyword_and => .bool_and,
        .keyword_or => .bool_or,
        else => unreachable,
    };

    const rule = p.getRule(p.current());
    const main_token = p.advance();
    // We use one higher level of precedence for the right operand because the binary operators are left-associative.
    const rhs = try p.parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

    return p.addNode(.{
        .tag = tag,
        .main_token = main_token,
        .data = .{ .node_and_node = .{ lhs, rhs } },
    });
}

fn function(p: *Parse) !Node.Index {
    // A fn declaration is a top-level form, not an expression operand
    // (grammar.y: `declaration`, never `primary`).
    if (p.nesting != 1) {
        return p.failMsg(.{ .tag = .expected_expression, .token = p.token_index });
    }
    const fn_token = p.advance();
    const proto = try p.parseProto(fn_token);

    if (!p.check(.l_brace)) return p.failExpected(.l_brace);
    const body = try p.block();

    return p.addNode(.{
        .tag = .fn_decl,
        .main_token = fn_token,
        .data = .{ .node_and_node = .{ proto, body } },
    });
}

/// An extern function is a bare `fn_proto` with no body; the `extern`
/// keyword is the token before the proto's `fn` token.
fn externFunction(p: *Parse) !Node.Index {
    // Same top-level-only rule as `function`.
    if (p.nesting != 1) {
        return p.failMsg(.{ .tag = .expected_expression, .token = p.token_index });
    }
    _ = p.advance(); // `extern`
    const fn_token = try p.consume(.keyword_fn);
    return p.parseProto(fn_token);
}

fn block(p: *Parse) !Node.Index {
    const main_token = p.advance();
    const span = try p.parseBlock(.brace_block);
    const r_brace = try p.consume(.r_brace);

    return p.addNode(.{
        .tag = .block,
        .main_token = main_token,
        .data = .{
            .extra = try p.addExtra(Node.Block{
                .expressions_start = span.start,
                .expressions_end = span.end,
                .rbrace = r_brace,
            }),
        },
    });
}

/// `if cond { a } else { b }` — if-as-expression with block branches and no
/// parens around the condition (grammar.y `ifExpr`). The condition parse
/// stops at `{` naturally: `l_brace` has no infix rule. `else` is optional;
/// its branch is a block or another `if` (else-if chains). The `else` must
/// follow the then-block's `}` on the same line — a newline in between ends
/// the statement.
fn ifExpr(p: *Parse) !Node.Index {
    const if_token = p.advance();
    const cond = try p.expression();

    if (!p.check(.l_brace)) return p.failExpected(.l_brace);
    const then_expr = try p.block();

    if (!p.check(.keyword_else)) {
        return p.addNode(.{
            .tag = .if_simple,
            .main_token = if_token,
            .data = .{ .node_and_node = .{ cond, then_expr } },
        });
    }
    _ = p.advance(); // `else`

    const else_expr = if (p.check(.keyword_if))
        try p.ifExpr()
    else if (p.check(.l_brace))
        try p.block()
    else
        return p.failExpected(.l_brace);

    return p.addNode(.{
        .tag = .if_else,
        .main_token = if_token,
        .data = .{ .node_and_extra = .{
            cond,
            try p.addExtra(Node.If{ .then_expr = then_expr, .else_expr = else_expr }),
        } },
    });
}

fn grouping(p: *Parse) !Node.Index {
    const main_token = p.advance();
    const inner = try p.expression();
    const r_paren = try p.consume(.r_paren);

    return p.addNode(.{
        .tag = .grouped_expression,
        .main_token = main_token,
        .data = .{ .node_and_token = .{ inner, r_paren } },
    });
}

fn call(p: *Parse, lhs: Node.Index) !Node.Index {
    const scratch_top = p.scratch.items.len;
    defer p.scratch.shrinkRetainingCapacity(scratch_top);
    const lparen = p.advance();

    // Only a plain identifier callee is supported today; AstGen has no
    // error reporting yet, so the check stays in the parser.
    switch (p.nodes.items(.tag)[@intFromEnum(lhs)]) {
        .identifier => {},
        else => return p.failMsg(.{
            .tag = .expected_callee,
            .token = p.nodes.items(.main_token)[@intFromEnum(lhs)],
        }),
    }

    while (true) {
        if (p.check(.r_paren)) break;
        const arg = try p.expression();
        try p.scratch.append(p.gpa, arg);

        if (!p.check(.comma)) break;
        _ = p.advance();
    }

    const r_paren = try p.consume(.r_paren);

    const span = try p.listToSpan(p.scratch.items[scratch_top..]);
    const args = try p.addExtra(Node.Call{
        .args_start = span.start,
        .args_end = span.end,
        .rparen = r_paren,
    });

    return p.addNode(.{
        .tag = .call,
        .main_token = lparen,
        .data = .{ .node_and_extra = .{ lhs, args } },
    });
}

// example: x = 1
fn bind(p: *Parse, lhs: Node.Index) !Node.Index {
    const main_token = p.advance();
    // Same precedence for the right operand (no +1 like `binary`) because
    // `=` is right-associative: `a = b = c` parses as `a = (b = c)`.
    const rhs = try p.parsePrecedence(.prec_assignment);

    return p.addNode(.{ .tag = .assign, .main_token = main_token, .data = .{ .node_and_node = .{ lhs, rhs } } });
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

/// return the lexeme of a token
fn tokenSlice(p: *Parse, token_index: TokenIndex) []const u8 {
    const token_tag = p.tokenTag(token_index);

    // Many tokens can be determined entirely by their tag.
    if (token_tag.lexeme()) |lexeme| {
        return lexeme;
    }

    // For some tokens, re-tokenization is needed to find the end.
    var scanner: Scanner = .{
        .buffer = p.source,
        .index = p.tokenStart(token_index),
        .line = 0,
    };
    const token = scanner.next();
    assert(token.tag == token_tag);
    return p.source[token.loc.start..token.loc.end];
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
