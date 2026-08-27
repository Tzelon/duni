const std = @import("std");

pub const Scanner = struct {
    buffer: [:0]const u8,
    index: usize,
    line: usize,

    /// Whether the previous significant token can end an expression — drives
    /// automatic newline insertion (see `endExpression`).
    insert_newline: bool = false,

    const State = enum {
        start,
        identifier,
        string_literal,
        string_literal_backslash,
        number,
        number_dot,
        number_exponent,
        float,
        float_exponent,
        invalid,
    };

    /// For debugging purposes.
    pub fn dump(self: *Scanner, token: *const Token) void {
        std.debug.print("{s} \"{s}\" -- {} \n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end], token.loc });
    }

    pub fn init(source: [:0]const u8) Scanner {
        return Scanner{ .buffer = source, .index = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0, .line = 1 };
    }

    pub fn next(self: *Scanner) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{ .start = self.index, .end = undefined },
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                // end of file
                0 => {
                    if (self.index == self.buffer.len) {
                        return .{ .tag = .eof, .loc = .{ .start = self.index, .end = self.index } };
                    } else {
                        continue :state .invalid;
                    }
                },
                // ignore white space
                ' ', '\t', '\r' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '\n' => {
                    self.index += 1;
                    self.line += 1;
                    if (!self.insert_newline) {
                        result.loc.start = self.index;
                        continue :state .start;
                    }
                    result.tag = .newline;
                },
                '0'...'9' => {
                    result.tag = .number_literal;
                    self.index += 1;
                    continue :state .number;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '"' => {
                    result.tag = .string_literal;
                    continue :state .string_literal;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;
                },
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                '+' => {
                    result.tag = .plus;
                    self.index += 1;
                },
                '-' => {
                    result.tag = .minus;
                    self.index += 1;
                },
                '*' => {
                    result.tag = .star;
                    self.index += 1;
                },
                '/' => {
                    result.tag = .slash;
                    self.index += 1;
                },
                '=' => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        '=' => {
                            result.tag = .equal_equal;
                            self.index += 1;
                        },
                        // TODO(tzelon) - enable later
                        // '>' => {
                        //     result.tag = .equal_angle_bracket_right;
                        //     self.index += 1;
                        // },
                        else => result.tag = .equal,
                    }
                },
                '!' => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        '=' => {
                            result.tag = .bang_equal;
                            self.index += 1;
                        },
                        else => result.tag = .bang,
                    }
                },
                '<' => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        '=' => {
                            result.tag = .angle_left_equal;
                            self.index += 1;
                        },
                        else => result.tag = .angle_left,
                    }
                },
                '>' => {
                    self.index += 1;
                    switch (self.buffer[self.index]) {
                        '=' => {
                            result.tag = .angle_right_equal;
                            self.index += 1;
                        },
                        else => result.tag = .angle_right,
                    }
                },
                '{' => {
                    result.tag = .l_brace;
                    self.index += 1;
                },
                '}' => {
                    result.tag = .r_brace;
                    self.index += 1;
                },
                else => continue :state .invalid,
            },

            .identifier => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    '?' => self.index += 1, // consume and end token
                    '!' => {
                        // A trailing `!` belongs to the name (Elixir-style,
                        // `map!`) — unless it begins `!=`, the inequality
                        // operator: `x != y` and `x!= y` both compare.
                        if (self.buffer[self.index + 1] == '=') {
                            const ident = self.buffer[result.loc.start..self.index];
                            if (Token.getKeyword(ident)) |tag| {
                                result.tag = tag;
                            }
                        } else {
                            self.index += 1; // consume and end token
                        }
                    },
                    else => {
                        const ident = self.buffer[result.loc.start..self.index];
                        if (Token.getKeyword(ident)) |tag| {
                            result.tag = tag;
                        }
                    },
                }
            },

            .string_literal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else {
                            result.tag = .invalid;
                        }
                    },
                    '\n' => result.tag = .invalid,
                    '\\' => continue :state .string_literal_backslash,
                    '"' => self.index += 1,
                    // ASCII control characters (bell, backspace, tab, escape, DEL, ...) are rejected inside strings.
                    // Excluded: 0x00 (EOF sentinel) and 0x0a (\n), handled above.
                    // https://en.wikipedia.org/wiki/ASCII#Control_characters
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string_literal,
                }
            },

            .string_literal_backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => result.tag = .invalid,
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string_literal,
                }
            },

            // Numbers
            .number => switch (self.buffer[self.index]) {
                '.' => continue :state .number_dot,
                // digit separator (1_000_000)
                '_',
                // zig fmt: off
                // hex digit + suffix letters
                'a'...'d', 'A'...'D',
                'f'...'o', 'F'...'O',
                'q'...'z', 'Q'...'Z',
                // zig fmt: on
                // digit
                '0'...'9',
                => {
                    self.index += 1;
                    continue :state .number;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .number_exponent;
                },
                else => {},
            },
            .number_exponent => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .number,
                }
            },
            // float or field access
            .number_dot => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    'e', 'E', 'p', 'P' => {
                        continue :state .float_exponent;
                    },
                    else => self.index -= 1, // parse the dot as field access
                }
            },
            .float => switch (self.buffer[self.index]) {
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .float;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .float_exponent;
                },
                else => {},
            },
            .float_exponent => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .float,
                }
            },

            .invalid => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => if (self.index == self.buffer.len) {
                        result.tag = .invalid;
                    } else {
                        continue :state .invalid;
                    },
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },
        }

        result.loc.end = self.index;
        self.insert_newline = endExpression(result.tag);
        return result;
    }

    fn endExpression(tag: Token.Tag) bool {
        return switch (tag) {
            .identifier,
            .r_paren,
            .r_brace,
            .number_literal,
            .string_literal,
            .keyword_true,
            .keyword_false,
            .invalid,
            => true,
            else => false,
        };
    }
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "fn", .keyword_fn },
        .{ "extern", .keyword_extern },
        .{ "true", .keyword_true },
        .{ "false", .keyword_false },
        .{ "if", .keyword_if },
        .{ "else", .keyword_else },
        .{ "and", .keyword_and },
        .{ "or", .keyword_or },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Loc = struct { start: usize, end: usize };

    pub const Tag = enum {
        identifier,

        // Literals.
        number_literal,
        string_literal,

        // Operators tokens.
        equal,
        plus,
        minus,
        star,
        slash,
        equal_equal,
        bang,
        bang_equal,
        angle_left,
        angle_left_equal,
        angle_right,
        angle_right_equal,

        comma,

        // Single-character tokens.
        l_paren,
        r_paren,
        l_brace,
        r_brace,

        // keywords
        keyword_fn,
        keyword_extern,
        keyword_true,
        keyword_false,
        keyword_if,
        keyword_else,
        keyword_and,
        keyword_or,

        // Expression end
        newline,

        // End
        invalid,
        eof,

        /// A human-readable name for the tag, for error messages: the fixed
        /// lexeme when the tag has one, a description otherwise.
        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .invalid => "invalid token",
                .identifier => "an identifier",
                .number_literal => "a number literal",
                .string_literal => "a string literal",
                .newline => "a newline",
                .eof => "EOF",
                else => unreachable,
            };
        }

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .identifier,
                .eof,
                .number_literal,
                .string_literal,
                .newline,
                => null,

                .keyword_fn => "fn",
                .keyword_extern => "extern",
                .keyword_true => "true",
                .keyword_false => "false",
                .keyword_if => "if",
                .keyword_else => "else",
                .keyword_and => "and",
                .keyword_or => "or",
                .equal => "=",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .equal_equal => "==",
                .bang => "!",
                .bang_equal => "!=",
                .angle_left => "<",
                .angle_left_equal => "<=",
                .angle_right => ">",
                .angle_right_equal => ">=",
                .comma => ",",
                .l_paren => "(",
                .r_paren => ")",
                .l_brace => "{",
                .r_brace => "}",
            };
        }
    };
};

fn expectToken(source: [:0]const u8, expected: []const Token.Tag) !void {
    var scanner = Scanner.init(source);

    for (expected) |tag| {
        try std.testing.expectEqual(tag, scanner.next().tag);
    }

    try std.testing.expectEqual(Token.Tag.eof, scanner.next().tag);
}

test "tokenizer" {
    try expectToken("42", &.{.number_literal});
    try expectToken("1_000_000", &.{.number_literal});
    try expectToken("0xDEAD_BEEF", &.{.number_literal});
    try expectToken("1e10", &.{.number_literal});
    try expectToken("-2", &.{ .minus, .number_literal });
    try expectToken("1e-5", &.{.number_literal});
    try expectToken("3.14", &.{.number_literal});
    try expectToken("1 * (2 + 3) / 5 - 2", &.{ .number_literal, .star, .l_paren, .number_literal, .plus, .number_literal, .r_paren, .slash, .number_literal, .minus, .number_literal });
    try expectToken("x = 1\n\ny", &.{ .identifier, .equal, .number_literal, .newline, .identifier });
    try expectToken("1 +\n2", &.{ .number_literal, .plus, .number_literal });
    try expectToken("empty? map!x", &.{ .identifier, .identifier, .identifier });
    try expectToken("\"hello world\"", &.{.string_literal});
    try expectToken("\"a\"\nx", &.{ .string_literal, .newline, .identifier });
    try expectToken("\"abc", &.{.invalid});
    try expectToken("\"a\nb", &.{ .invalid, .newline, .identifier });
    try expectToken("\"a\\\"b\"", &.{.string_literal});
    try expectToken("}\nx", &.{ .r_brace, .newline, .identifier });
    try expectToken("extern fn add(x number, y number) number", &.{ .keyword_extern, .keyword_fn, .identifier, .l_paren, .identifier, .identifier, .comma, .identifier, .identifier, .r_paren, .identifier });
    try expectToken("true false if else and or", &.{ .keyword_true, .keyword_false, .keyword_if, .keyword_else, .keyword_and, .keyword_or });
    try expectToken("1 == 2 != 3", &.{ .number_literal, .equal_equal, .number_literal, .bang_equal, .number_literal });
    try expectToken("1 < 2 <= 3 > 4 >= 5", &.{ .number_literal, .angle_left, .number_literal, .angle_left_equal, .number_literal, .angle_right, .number_literal, .angle_right_equal, .number_literal });
    try expectToken("!x", &.{ .bang, .identifier });
    // `x!` is an Elixir-style name ending — unless the `!` begins `!=`.
    try expectToken("x != y", &.{ .identifier, .bang_equal, .identifier });
    try expectToken("x!= y", &.{ .identifier, .bang_equal, .identifier });
    try expectToken("map!x", &.{ .identifier, .identifier });
    // `true` ends an expression: a following newline is a statement break.
    try expectToken("x = true\ny", &.{ .identifier, .equal, .keyword_true, .newline, .identifier });
}
