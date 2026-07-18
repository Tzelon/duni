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
                        // TODO(tzelon) - enable later
                        // '=' => {
                        //     result.tag = .equal_equal;
                        //     self.index += 1;
                        // },
                        // '>' => {
                        //     result.tag = .equal_angle_bracket_right;
                        //     self.index += 1;
                        // },
                        else => result.tag = .equal,
                    }
                },
                else => continue :state .invalid,
            },

            .identifier => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
                    '!', '?' => self.index += 1, // consume and end token
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

            .invalid => unreachable,
        }

        result.loc.end = self.index;
        self.insert_newline = endExpression(result.tag);
        return result;
    }

    fn endExpression(tag: Token.Tag) bool {
        return switch (tag) {
            .identifier,
            .r_paren,
            .number_literal,
            .string_literal,
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

        // Single-character tokens.
        l_paren,
        r_paren,

        // keywords
        keyword_fn,

        // Expression end
        newline,

        // End
        invalid,
        eof,

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
                .equal => "=",
                .plus => "+",
                .minus => "-",
                .star => "*",
                .slash => "/",
                .l_paren => "(",
                .r_paren => ")",
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
    try expectToken("\"a\nb", &.{ .invalid, .identifier });
}
