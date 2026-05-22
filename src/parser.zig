const std = @import("std");
const Token = @import("./scanner.zig").Token;
const Ast = @import("./ast.zig");

const log = std.log.scoped(.parser);

const Allocator = std.mem.Allocator;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const ExtraIndex = Ast.ExtraIndex;
const assert = std.debug.assert;

pub const Error = error{ParseError} || Allocator.Error;

pub const Parser = struct {
    gpa: Allocator,
    /// source text
    source: [:0]const u8,
    /// list of AST nodes
    nodes: std.MultiArrayList(Node),
    /// list of recoverable errors
    errors: std.ArrayListUnmanaged(Ast.Error),
    token_tags: []const Token.Tag,
    token_starts: []const Ast.ByteOffset,
    /// current token index
    token_index: TokenIndex,
    /// extra data refereced by AST node. exmaple: function params
    extra_data: std.ArrayListUnmanaged(u32),
    /// temp array of nodes
    scratch: std.ArrayListUnmanaged(Node.Index),

    pub fn deinit(self: *Parser) void {
        self.errors.deinit(self.gpa);
        self.nodes.deinit(self.gpa);
        self.extra_data.deinit(self.gpa);
        self.scratch.deinit(self.gpa);
    }

    pub fn parse(self: *Parser) !void {

        // TODO: parse function body

        // Root node must be index 0.
        self.nodes.appendAssumeCapacity(.{
            .tag = .root,
            .main_token = 0,
            .data = undefined,
        });

        const root_members = try self.parseContainerMembers();
        const root_decls = try root_members.toSpan(self);

        if (self.token_tags[self.token_index] != .eof) {
            try self.warnExpected(.eof);
        }

        self.nodes.items(.data)[0] = .{ .extra_range = root_decls };
    }

    fn parseContainerMembers(self: *Parser) Allocator.Error!Members {
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            switch (self.current()) {
                .keyword_fn => {
                    const maybe_top_level_decl = try self.expectTopLevelDeclRecoverable();
                    if (maybe_top_level_decl) |top_level_decl| {
                        log.info("current {any} \n", .{top_level_decl});
                        try self.scratch.append(self.gpa, top_level_decl);
                    }
                },
                .eof => {
                    break;
                },
                else => {
                    try self.warn(.expected_return_type);
                    _ = self.advance();
                    continue;
                },
            }
        }

        const items = self.scratch.items[scratch_top..];
        log.info("current {any} \n", .{items});

        if (items.len <= 2) {
            return Members{
                .len = items.len,
                .data = .{ .opt_node_and_opt_node = .{
                    if (items.len >= 1) items[0].toOptional() else .none,
                    if (items.len >= 2) items[1].toOptional() else .none,
                } },

                // TODO: remove trailing
                .trailing = false,
            };
        } else {
            return Members{
                .len = items.len,
                .data = .{ .extra_range = try self.listToSpan(items) },
                .trailing = false,
            };
        }
    }

    fn expectTopLevelDeclRecoverable(self: *Parser) error{OutOfMemory}!?Node.Index {
        return self.expectTopLevelDecl() catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ParseError => {
                log.info("ParseError on top_level_decl \n", .{});
                // self.findNextContainerMember();
                return null;
            },
        };
    }

    fn expectTopLevelDecl(self: *Parser) !?Node.Index {
        switch (self.current()) {
            .keyword_fn => {
                return self.function();
            },
            else => {
                try self.warn(.expected_fn);
                return error.ParseError;
            },
        }
    }

    /// FnProto <- KEYWORD_fn IDENTIFIER? LPAREN ParamDeclList RPAREN TypeExpr
    fn function(self: *Parser) !?Node.Index {
        const fn_token = try self.consume(.keyword_fn);
        // We want the fn proto node to be before its children in the array.
        const fn_proto_index = try self.reserveNode(.fn_proto);
        errdefer self.unreserveNode(fn_proto_index);

        _ = try self.consume(.identifier);
        log.info("identifier consumed \n", .{});

        const params = try self.functionParams();
        log.info("params consumed {any} \n", .{params});

        const return_type_expr = try self.parseTypeExpr();
        if (return_type_expr == null) {
            // most likely the user forgot to specify the return type.
            // Mark return type as invalid and try to continue.
            try self.warn(.expected_return_type);
        }
        log.info("return type consumed {any} \n", .{return_type_expr});

        const fn_proto = switch (params) {
            //TODO: optimize 1 or less params see other comment
            .zero_or_one => {
                unreachable;
            },
            .multi => |span| self.setNode(fn_proto_index, .{
                .tag = .fn_proto,
                .main_token = fn_token,
                .data = .{ .extra_and_opt_node = .{
                    try self.addExtra(Node.SubRange{
                        .start = span.start,
                        .end = span.end,
                    }),
                    .fromOptional(return_type_expr),
                } },
            }),
        };

        log.info("fn_proto created {any} \n", .{fn_proto});

        switch (self.current()) {
            .l_brace => {
                const fn_decl_index = try self.reserveNode(.fn_decl);
                errdefer self.unreserveNode(fn_decl_index);

                // parse block
                const body_block = try self.block();
                return self.setNode(fn_decl_index, .{
                    .tag = .fn_decl,
                    .main_token = self.nodeMainToken(fn_proto),
                    .data = .{ .node_and_node = .{
                        fn_proto,
                        body_block.?,
                    } },
                });
            },
            else => {
                // Since parseBlock only return error.ParseError on
                // a missing '}' we can assume this function was
                // supposed to end here.
                try self.warn(.expected_semi_or_lbrace);
                return null;
            },
        }
    }

    /// Block <- LBRACE BlockStatement* RBRACE
    fn block(self: *Parser) !?Node.Index {
        const lbrace = self.consume(.l_brace) catch return null;
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        // parse expressions
        while (true) {
            if (self.check(.r_brace)) break;
            const expr = try self.expression();
            try self.scratch.append(self.gpa, expr);
        }

        _ = try self.consume(.r_brace);

        const expressions = self.scratch.items[scratch_top..];
        return try self.addNode(.{
            .tag = .block,
            .main_token = lbrace,
            .data = .{ .extra_range = try self.listToSpan(expressions) },
        });
    }

    /// params list are stored in the extra_data list
    /// ParamDeclList <- (ParamDecl COMMA)* ParamDecl?
    /// ParamDecl <- (IDENTIFIER COLON)? ParamType
    fn functionParams(self: *Parser) !SmallSpan {
        _ = try self.consume(.l_paren);
        const scratch_top = self.scratch.items.len;
        defer self.scratch.shrinkRetainingCapacity(scratch_top);

        while (true) {
            if (self.check(.r_paren)) {
                break;
            }

            //parse param declaration
            _ = try self.consume(.identifier);

            const maybe_param = try self.expectTypeExpr();
            if (maybe_param) |param| {
                try self.scratch.append(self.gpa, param);
            }
            // end

            switch (self.current()) {
                .comma => self.token_index += 1,
                .r_paren => {
                    self.token_index += 1;
                    break;
                },
                .r_brace => return self.failExpected(.r_paren),
                // Likely just a missing comma; give error but continue parsing.
                else => try self.warn(.expected_comma_after_param),
            }
        }

        const params = self.scratch.items[scratch_top..];

        //TODO: optimize for 1 or less params https://github.com/ziglang/zig/blob/92ae5818d26925af7816fabcaec85236133b9e46/lib/std/zig/Parse.zig#L3840
        return SmallSpan{ .multi = try self.listToSpan(params) };
    }

    fn expectTypeExpr(self: *Parser) Error!?Node.Index {
        const node = try self.parseTypeExpr();
        if (node == null) {
            return self.fail(.expected_type_expr);
        }
        return node;
    }

    /// PrimaryTypeExpr
    ///     <- COLON CHAR_LITERAL
    ///      / COLON FLOAT
    ///      / COLON IDENTIFIER
    ///      / COLON INTEGER
    ///      / COLON STRINGLITERAL
    fn parseTypeExpr(self: *Parser) Error!?Node.Index {
        _ = try self.consume(.colon);

        switch (self.current()) {
            //TODO: parse optional type
            // .question_mark => return self.addNode(.{
            //     .tag = .optional_type,
            //     .main_token = self.advance(),
            //     .data = .{
            //         .lhs = try self.expectTypeExpr(),
            //         .rhs = undefined,
            //     },
            // }),

            //TODO: should I parse a pattern?
            .identifier => {
                const main_token = self.advance();
                return try self.addNode(.{
                    .tag = .identifier,
                    .main_token = main_token,
                    .data = undefined,
                });
            },
            else => return null,
        }
    }

    fn expression(self: *Parser) !Node.Index {
        log.info("parse expression", .{});
        return try self.parsePrecedence(.prec_assignment);
    }

    fn parsePrecedence(self: *Parser, precedence: Precedence) !Node.Index {
        const prefixRule = self.getRule(self.current()).prefix orelse {
            return self.failMsg(.{
                .tag = .expected_expression,
                .token = self.token_index,
            });
        };

        var node = try prefixRule(self);

        while (@intFromEnum(precedence) <= @intFromEnum(self.getRule(self.current()).precedence)) {
            const infixRule = self.getRule(self.current()).infix orelse {
                return self.failMsg(.{
                    .tag = .expected_expression,
                    .token = self.token_index,
                });
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
            .data = .{ .node_and_node = .{ lhs, rhs } },
        });
    }

    /// PrefixExpr <- PrefixOp* PrimaryExpr
    ///
    /// PrefixOp
    ///     <- EXCLAMATIONMARK
    ///      / MINUS
    fn unary(self: *Parser) !Node.Index {
        const tag: Node.Tag = switch (self.token_tags[self.token_index]) {
            .bang => .bool_not,
            .minus => .negation,
            else => unreachable,
        };
        return self.addNode(.{ .tag = tag, .main_token = self.advance(), .data = .{ .node = try self.parsePrecedence(.prec_unary) } });
    }

    /// example: `(` expression `)`
    fn grouping(self: *Parser) !Node.Index {
        return self.addNode(.{
            .tag = .grouped_expression,
            .main_token = self.advance(),
            .data = .{ .node_and_token = .{ try self.expression(), try self.consume(.r_paren) } },
        });
    }

    /// example: 47
    fn number(self: *Parser) !Node.Index {
        return self.addNode(.{
            .tag = .number_literal,
            .main_token = self.advance(),
            .data = undefined,
        });
    }

    fn string(self: *Parser) !Node.Index {
        return self.addNode(.{
            .tag = .string_literal,
            .main_token = self.advance(),
            .data = undefined,
        });
    }

    fn variable(self: *Parser) !Node.Index {
        _ = self.advance();
        const equal_token = try self.consume(.equal);
        const initializer = try self.expression();

        return self.addNode(.{
            .tag = .bind,
            .main_token = equal_token,
            .data = .{
                .opt_node_and_node = .{
                    // Empty space type expression, if we ever need it.
                    Node.OptionalIndex.none,
                    initializer,
                },
            },
        });
    }

    // node helpers

    fn nodeMainToken(self: *const Parser, node: Node.Index) TokenIndex {
        return self.nodes.items(.main_token)[@intFromEnum(node)];
    }

    fn addNode(self: *Parser, elem: Ast.Node) Allocator.Error!Node.Index {
        const result: Node.Index = @enumFromInt(self.nodes.len);
        try self.nodes.append(self.gpa, elem);
        return result;
    }

    fn setNode(self: *Parser, i: usize, elem: Ast.Node) Node.Index {
        self.nodes.set(i, elem);
        return @enumFromInt(i);
    }

    /// save a spot in the nodes list
    fn reserveNode(self: *Parser, tag: Ast.Node.Tag) !usize {
        try self.nodes.resize(self.gpa, self.nodes.len + 1);
        self.nodes.items(.tag)[self.nodes.len - 1] = tag;
        return self.nodes.len - 1;
    }

    /// remove the spot from the nodes list
    fn unreserveNode(self: *Parser, node_index: usize) void {
        if (self.nodes.len == node_index) {
            self.nodes.resize(self.gpa, self.nodes.len - 1) catch unreachable;
        } else {
            // There is zombie node left in the tree, let's make it as inoffensive as possible
            // (sadly there's no no-op node)
            self.nodes.items(.tag)[node_index] = .unreachable_literal;
            self.nodes.items(.main_token)[node_index] = self.token_index;
        }
    }

    /// take a list of Node.Index an return SubRange to extra_data
    fn listToSpan(self: *Parser, list: []const Node.Index) Allocator.Error!Node.SubRange {
        try self.extra_data.appendSlice(self.gpa, @ptrCast(list));

        return .{
            .start = @enumFromInt(self.extra_data.items.len - list.len),
            .end = @enumFromInt(self.extra_data.items.len),
        };
    }

    /// append extra data to the extra_data list, can be any struct
    fn addExtra(self: *Parser, extra: anytype) Allocator.Error!ExtraIndex {
        const fields = std.meta.fields(@TypeOf(extra));
        try self.extra_data.ensureUnusedCapacity(self.gpa, fields.len);
        const result: ExtraIndex = @enumFromInt(self.extra_data.items.len);
        inline for (fields) |field| {
            const data: u32 = switch (field.type) {
                Node.Index,
                Node.OptionalIndex,
                // OptionalTokenIndex,
                ExtraIndex,
                => @intFromEnum(@field(extra, field.name)),
                TokenIndex,
                => @field(extra, field.name),
                else => @compileError("unexpected field type"),
            };
            self.extra_data.appendAssumeCapacity(data);
        }
        return result;
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
            .identifier => comptime ParseRule.init(Parser.variable, null, .prec_none),
            .string_literal => comptime ParseRule.init(Parser.string, null, .prec_none),
            .number_literal => comptime ParseRule.init(Parser.number, null, .prec_none),
            // .keyword_and => comptime ParseRule.init(null, Parser.@"and", .prec_and),
            // TokenType.TOKEN_CLASS => comptime ParseRule.init(null, null, .PREC_NONE),
            .keyword_else => comptime ParseRule.init(null, null, .prec_none),
            // .keyword_false => comptime ParseRule.init(Parser.literal, null, .prec_none),
            // .keyword_true => comptime ParseRule.init(Parser.literal, null, .prec_none),
            .keyword_for => comptime ParseRule.init(null, null, .prec_none),
            .keyword_fn => comptime ParseRule.init(null, null, .prec_none),
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
                log.err("no rule for token {}", .{tag});
                unreachable;
            },
        };

        return rule;
    }

    /// fail functions return parse error
    fn fail(self: *Parser, tag: Ast.Error.Tag) error{ ParseError, OutOfMemory } {
        @branchHint(.cold);
        return self.failMsg(.{ .tag = tag, .token = self.token_index });
    }

    fn failExpected(self: *Parser, expected_token: Token.Tag) error{ ParseError, OutOfMemory } {
        @branchHint(.cold);
        return self.failMsg(.{
            .tag = .expected_token,
            .token = self.token_index,
            .extra = .{ .expected_tag = expected_token },
        });
    }

    fn failMsg(self: *Parser, msg: Ast.Error) error{ ParseError, OutOfMemory } {
        @branchHint(.cold);
        try self.warnMsg(msg);
        return error.ParseError;
    }

    /// warn functions adds an error to the errors list
    fn warn(self: *Parser, error_tag: Ast.Error.Tag) error{OutOfMemory}!void {
        @branchHint(.cold);
        try self.warnMsg(.{ .tag = error_tag, .token = self.token_index });
    }

    fn warnExpected(self: *Parser, expected_token: Token.Tag) error{OutOfMemory}!void {
        @branchHint(.cold);
        try self.warnMsg(.{
            .tag = .expected_token,
            .token = self.token_index,
            .extra = .{ .expected_tag = expected_token },
        });
    }

    fn warnMsg(self: *Parser, msg: Ast.Error) !void {
        @branchHint(.cold);
        switch (msg.tag) {
            .expected_comma_after_arg,
            .expected_return_type,
            .expected_token,
            .expected_expression,
            .expected_type_expr,
            .expected_semi_or_lbrace,
            .expected_comma_after_param,
            .expected_fn,
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

    /// return the current token in the sequence. without **advancing**
    fn current(self: *Parser) Token.Tag {
        return self.token_tags[self.token_index];
    }

    /// return the previous token in the sequence. without **advancing**
    fn previous(self: *Parser) Token.Tag {
        return self.token_tags[self.token_index - 1];
    }

    /// return the current token position and move to the next
    fn advance(self: *Parser) TokenIndex {
        const result = self.token_index;
        self.token_index += 1;
        return result;
    }

    /// return true if the current token has the given tag
    fn check(self: *Parser, expected_tag: Token.Tag) bool {
        return self.token_tags[self.token_index] == expected_tag;
    }

    /// consume the current token only if the current token matches the type
    fn consume(self: *Parser, expected_tag: Token.Tag) !TokenIndex {
        if (!self.check(expected_tag)) {
            log.info("failed to consume {}\n", .{expected_tag});
            return self.failExpected(expected_tag);
        }

        log.info("success to consume {}\n", .{expected_tag});

        return self.advance();
    }

    // Public Helpers

    pub fn renderError(self: *Parser, parse_error: Error, stream: anytype) !void {
        switch (parse_error.tag) {
            .expected_expression => {
                return stream.print("expected expression, found '{s}'", .{
                    self.token_tags[parse_error.token + @intFromBool(parse_error.token_is_prev)].symbol(),
                });
            },
            .expected_comma_after_arg => {
                return stream.writeAll("expected ',' after argument");
            },
            .expected_token => {
                const found_tag = self.token_tags[parse_error.token + @intFromBool(parse_error.token_is_prev)];
                const expected_symbol = parse_error.extra.expected_tag.symbol();
                switch (found_tag) {
                    .invalid => return stream.print("expected '{s}', found invalid bytes", .{
                        expected_symbol,
                    }),
                    else => return stream.print("expected '{s}', found '{s}'", .{
                        expected_symbol, found_tag.symbol(),
                    }),
                }
            },
        }
    }

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

const ParsePrefixFn = *const fn (parser: *Parser) Error!Node.Index;
const ParseInfixFn = *const fn (parser: *Parser, lhs: Node.Index) Error!Node.Index;

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

pub const Location = struct {
    line: usize,
    column: usize,
    line_start: usize,
    line_end: usize,
};

const SmallSpan = union(enum) {
    zero_or_one: Node.Index,
    multi: Node.SubRange,
};

const Members = struct {
    len: usize,
    /// Must be either `.opt_node_and_opt_node` if `len <= 2` or `.extra_range` otherwise.
    data: Node.Data,
    trailing: bool,

    fn toSpan(self: Members, parser: *Parser) !Node.SubRange {
        return switch (self.len) {
            0 => parser.listToSpan(&.{}),
            1 => parser.listToSpan(&.{self.data.opt_node_and_opt_node[0].unwrap().?}),
            2 => parser.listToSpan(&.{ self.data.opt_node_and_opt_node[0].unwrap().?, self.data.opt_node_and_opt_node[1].unwrap().? }),
            else => self.data.extra_range,
        };
    }
};

fn listToSpan(self: *Parser, list: []const Node.Index) !Node.SubRange {
    try self.extra_data.appendSlice(self.gpa, list);
    return Node.SubRange{
        .start = @as(Node.Index, @intCast(self.extra_data.items.len - list.len)),
        .end = @as(Node.Index, @intCast(self.extra_data.items.len)),
    };
}

test {
    _ = @import("./parser_test.zig");
}
