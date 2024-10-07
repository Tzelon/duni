const std = @import("std");
const Scanner = @import("./scanner.zig").Scanner;
const Token = @import("./scanner.zig").Token;
const Ast = @import("./ast.zig");

const Allocator = std.mem.Allocator;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;

const null_node: Node.Index = 0;

pub const Parser = struct {
    source: [:0]const u8,
    nodes: std.MultiArrayList(Node),
    errors: std.ArrayListUnmanaged(Error),
    tokens: Ast.TokenList,
    token_tags: []const Token.Tag,
    token_starts: []const Ast.ByteOffset,
    gpa: Allocator,
    token_index: TokenIndex,

    pub fn init(source: [:0]const u8, gpa: Allocator) !Parser {
        var tokens = Ast.TokenList{};

        // Empirically, the zig std lib has an 8:1 ratio of source bytes to token count.
        const estimated_token_count = source.len / 8;
        try tokens.ensureTotalCapacity(gpa, estimated_token_count);
        var scanner = Scanner.init(source);

        while (true) {
            const token = scanner.next();
            try tokens.append(gpa, .{
                .tag = token.tag,
                .start = @intCast(token.loc.start),
            });
            if (token.tag == .eof) break;
        }

        return Parser{
            .gpa = gpa,
            .errors = .{},
            .nodes = .{},
            .source = source,
            .tokens = tokens,
            .token_tags = tokens.items(.tag),
            .token_starts = tokens.items(.start),
            .token_index = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.errors.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.tokens.deinit(self.gpa);
        // self.extra_data.deinit(self.gpa);
        // self.scratch.deinit(self.gpa);
    }

    pub fn parse(self: *Parser) !void {
        const estimated_node_count = (self.tokens.len + 2) / 2;
        // Empirically, Zig source code has a 2:1 ratio of tokens to AST nodes.
        // Make sure at least 1 so we can use appendAssumeCapacity on the root node below.
        try self.nodes.ensureTotalCapacity(self.gpa, estimated_node_count);
        // Root node must be index 0.
        self.nodes.appendAssumeCapacity(.{
            .tag = .root,
            .main_token = 0,
            .data = undefined,
        });

        std.debug.print("tokens {any}  \n", .{self.token_tags});
        _ = try self.expression();
        _ = try self.consume(.eof);
    }

    pub fn expression(self: *Parser) !Node.Index {
        return try self.parsePrecedence(.prec_assignment);
    }

    fn parsePrecedence(self: *Parser, precedence: Precedence) !Node.Index {
        const prefixRule = self.getRule(self.current()).prefix orelse {
            try self.failMsg(.{
                .tag = .expected_expression,
                .token = self.token_index,
            });

            return null_node;
        };

        var node = try prefixRule(self);

        while (@intFromEnum(precedence) <= @intFromEnum(self.getRule(self.current()).precedence)) {
            const infixRule = self.getRule(self.current()).infix orelse {
                try self.failMsg(.{
                    .tag = .expected_expression,
                    .token = self.token_index,
                });

                return node;
            };

            node = try infixRule(self, node);
        }

        return node;
    }

    /// example: 1 + 1
    fn binary(self: *Parser, lhs: Node.Index) !Node.Index {
        const tag: Node.Tag = switch (self.current()) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            else => unreachable,
        };

        const main_tk = self.token_index;
        _ = self.advance();

        const rule = self.getRule(self.current());
        // We use one higher level of precedence for the right operand because the binary operators are left-associative.
        const rhs = try self.parsePrecedence(@enumFromInt(@intFromEnum(rule.precedence) + 1));

        return self.addNode(.{
            .tag = tag,
            .main_token = main_tk,
            .data = .{
                .lhs = lhs,
                .rhs = rhs,
            },
        });
    }

    fn unary(self: *Parser) !Node.Index {
        const tag: Node.Tag = switch (self.token_tags[self.token_index]) {
            .bang => .bool_not,
            .minus => .negation,
            else => unreachable,
        };
        return self.addNode(.{ .tag = tag, .main_token = self.advance(), .data = .{ .lhs = try self.parsePrecedence(.prec_unary), .rhs = undefined } });
    }

    /// example: `(` expression `)`
    fn grouping(self: *Parser) !Node.Index {
        return self.addNode(.{
            .tag = .grouped_expression,
            .main_token = self.advance(),
            .data = .{
                .lhs = try self.expression(),
                .rhs = try self.consume(.r_paren),
            },
        });
    }

    /// example: 47
    fn number(self: *Parser) !Node.Index {
        return self.addNode(.{
            .tag = .number_literal,
            .main_token = self.advance(),
            .data = .{
                .lhs = undefined,
                .rhs = undefined,
            },
        });
    }

    fn addNode(self: *Parser, elem: Ast.Node) Allocator.Error!Node.Index {
        const result = @as(Node.Index, @intCast(self.nodes.len));
        try self.nodes.append(self.gpa, elem);
        return result;
    }

    /// return the current token position and move to the next
    fn advance(self: *Parser) TokenIndex {
        const result = self.token_index;
        self.token_index += 1;
        return result;
    }

    /// consume a token only if the current token matches the type
    pub fn consume(self: *Parser, expected_tag: Token.Tag) !TokenIndex {
        if (self.token_tags[self.token_index] != expected_tag) {
            return self.failMsg(.{
                .tag = .expected_token,
                .token = self.token_index,
                .extra = .{ .expected_tag = expected_tag },
            });
        }

        return self.advance();
    }

    fn getRule(self: *Parser, tag: Token.Tag) ParseRule {
        _ = self;
        const rule = switch (tag) {
            .l_paren => comptime ParseRule.init(Parser.grouping, null, .prec_call),
            .r_paren => comptime ParseRule.init(null, null, .prec_none),
            .l_brace => comptime ParseRule.init(null, null, .prec_none),
            .r_brace => comptime ParseRule.init(null, null, .prec_none),
            .comma => comptime ParseRule.init(null, null, .prec_none),
            // .dot => comptime ParseRule.init(null, Parser.dot, .prec_call),
            .minus => comptime ParseRule.init(Parser.unary, Parser.binary, .prec_term),
            .plus => comptime ParseRule.init(null, Parser.binary, .prec_term),
            // TokenType.TOKEN_SEMICOLON => comptime ParseRule.init(null, null, .PREC_NONE),
            .slash => comptime ParseRule.init(null, Parser.binary, .prec_factor),
            .star => comptime ParseRule.init(null, Parser.binary, .prec_factor),
            .bang => comptime ParseRule.init(Parser.unary, null, .prec_none),
            .bang_equal => comptime ParseRule.init(null, Parser.binary, .prec_equality),
            .equal => comptime ParseRule.init(null, null, .prec_none),
            .equal_equal => comptime ParseRule.init(null, Parser.binary, .prec_equality),
            .angle_bracket_left => comptime ParseRule.init(null, Parser.binary, .prec_comparison),
            .angle_bracket_left_equal => comptime ParseRule.init(null, Parser.binary, .prec_comparison),
            .angle_bracket_right => comptime ParseRule.init(null, Parser.binary, .prec_comparison),
            .angle_bracket_right_equal => comptime ParseRule.init(null, Parser.binary, .prec_comparison),
            // .identifier => comptime ParseRule.init(Parser.variable, null, .prec_none),
            // .string_literal => comptime ParseRule.init(Parser.string, null, .prec_none),
            .number_literal => comptime ParseRule.init(Parser.number, null, .prec_none),
            // .keyword_and => comptime ParseRule.init(null, Parser.@"and", .prec_and),
            // TokenType.TOKEN_CLASS => comptime ParseRule.init(null, null, .PREC_NONE),
            .keyword_else => comptime ParseRule.init(null, null, .prec_none),
            // .keyword_false => comptime ParseRule.init(Parser.literal, null, .prec_none),
            // .keyword_true => comptime ParseRule.init(Parser.literal, null, .prec_none),
            .keyword_for => comptime ParseRule.init(null, null, .prec_none),
            .keyword_fun => comptime ParseRule.init(null, null, .prec_none),
            .keyword_if => comptime ParseRule.init(null, null, .prec_none),
            // .keyword_nil => comptime ParseRule.init(Parser.literal, null, .prec_none),
            // .keyword_or => comptime ParseRule.init(null, Parser.@"or", .prec_or),
            .keyword_print => comptime ParseRule.init(null, null, .prec_none),
            // TokenType.TOKEN_RETURN => comptime ParseRule.init(null, null, .PREC_NONE),
            // TokenType.TOKEN_SUPER => comptime ParseRule.init(super, null, .PREC_NONE),
            // TokenType.TOKEN_THIS => comptime ParseRule.init(this, null, .PREC_NONE),
            // TokenType.TOKEN_VAR => comptime ParseRule.init(null, null, .PREC_NONE),
            // TokenType.TOKEN_WHILE => comptime ParseRule.init(null, null, .PREC_NONE),
            .keyword_error => comptime ParseRule.init(null, null, .prec_none),
            .eof => comptime ParseRule.init(null, null, .prec_none),
            else => {
                unreachable;
            },
        };

        return rule;
    }

    fn warnExpected(self: *Parser, expected_token: Token.Tag) error{OutOfMemory}!void {
        @branchHint(.cold);
        try self.warnMsg(.{
            .tag = .expected_token,
            .token = self.token_index,
            .extra = .{ .expected_tag = expected_token },
        });
    }

    fn warn(self: *Parser, error_tag: Error.Tag) error{OutOfMemory}!void {
        @branchHint(.cold);
        try self.warnMsg(.{ .tag = error_tag, .token = self.token_index });
    }

    fn failMsg(self: *Parser, msg: Error) error{ ParseError, OutOfMemory } {
        @branchHint(.cold);
        try self.warnMsg(msg);
        return error.ParseError;
    }

    fn warnMsg(self: *Parser, msg: Error) !void {
        @branchHint(.cold);
        switch (msg.tag) {
            .expected_comma_after_arg,
            .expected_token,
            .expected_expression,
            => if (msg.token != 0 and !self.tokensOnSameLine(msg.token - 1, msg.token)) {
                var copy = msg;
                copy.token_is_prev = true;
                copy.token -= 1;
                return self.errors.append(self.gpa, copy);
            },
            // else => {},
        }
        try self.errors.append(self.gpa, msg);
    }

    // Helpers

    fn tokensOnSameLine(self: *Parser, token1: TokenIndex, token2: TokenIndex) bool {
        return std.mem.indexOfScalar(u8, self.source[self.token_starts[token1]..self.token_starts[token2]], '\n') == null;
    }

    fn current(self: *Parser) Token.Tag {
        return self.token_tags[self.token_index];
    }

    fn previous(self: *Parser) Token.Tag {
        return self.token_tags[self.token_index - 1];
    }

    // Public Helpers

    pub fn tokenLocation(self: *Parser, start_offset: Ast.ByteOffset, token_index: TokenIndex) Location {
        var loc = Location{
            .line = 0,
            .column = 0,
            .line_start = start_offset,
            .line_end = self.source.len,
        };
        const token_start = self.token_starts[token_index];

        // Scan to by line until we go past the token start
        while (std.mem.indexOfScalarPos(u8, self.source, loc.line_start, '\n')) |i| {
            if (i >= token_start) {
                break; // Went past
            }
            loc.line += 1;
            loc.line_start = i + 1;
        }

        const offset = loc.line_start;
        for (self.source[offset..], 0..) |c, i| {
            if (i + offset == token_start) {
                loc.line_end = i + offset;
                while (loc.line_end < self.source.len and self.source[loc.line_end] != '\n') {
                    loc.line_end += 1;
                }
                return loc;
            }
            if (c == '\n') {
                loc.line += 1;
                loc.column = 0;
                loc.line_start = i + 1;
            } else {
                loc.column += 1;
            }
        }
        return loc;
    }
};

const ParsePrefixFn = *const fn (parser: *Parser) anyerror!Node.Index;
const ParseInfixFn = *const fn (parser: *Parser, lhs: Node.Index) anyerror!Node.Index;

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

pub const Error = struct {
    tag: Tag,
    is_note: bool = false,
    /// True if `token` points to the token before the token causing an issue.
    token_is_prev: bool = false,
    token: TokenIndex,
    extra: union { none: void, expected_tag: Token.Tag } = .{ .none = {} },

    pub const Tag = enum { expected_comma_after_arg, expected_token, expected_expression };
};

pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

test {
    _ = @import("./parser_test.zig");
}
