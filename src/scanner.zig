const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.StaticStringMap(Tag).initComptime(.{
        .{ "and", .keyword_and },
        .{ "else", .keyword_else },
        .{ "false", .keyword_false },
        .{ "true", .keyword_true },
        .{ "for", .keyword_for },
        .{ "fun", .keyword_fun },
        .{ "if", .keyword_if },
        .{ "nil", .keyword_nil },
        .{ "for", .keyword_or },
        .{ "print", .keyword_print },
        .{ "error", .keyword_error },
    });

    pub fn getKeyword(bytes: []const u8) ?Tag {
        return keywords.get(bytes);
    }

    pub const Tag = enum {

        // Single-character tokens.
        l_bracket,
        r_bracket,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        comma,
        dot,
        slash,
        colon,
        tilde,
        ellipsis2,
        ellipsis3,

        // One or two character tokens.
        bang,
        bang_equal,
        equal,
        equal_equal,
        angle_bracket_right,
        equal_angle_bracket_right,
        angle_bracket_left,
        angle_bracket_right_equal,
        angle_bracket_left_equal,
        less,
        less_equal,
        ampersand,
        ampersand_equal,
        star,
        star_star,
        star_equal,
        percent,
        percent_equal,
        plus,
        plus_equal,
        minus,
        minus_equal,

        // Literals.
        identifier,
        string_literal,
        number_literal,
        // Keywords.
        keyword_and,
        keyword_else,
        keyword_false,
        keyword_true,
        keyword_for,
        keyword_fun,
        keyword_if,
        keyword_nil,
        keyword_or,
        keyword_print,

        keyword_error,
        invalid,
        eof,

        doc_comment,
        doc_comment_start,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .identifier,
                .string_literal,
                .eof,
                .number_literal,
                .doc_comment,
                // .container_doc_comment,
                => null,

                .bang => "!",
                .equal => "=",
                .equal_equal => "==",
                .equal_angle_bracket_right => "=>",
                .bang_equal => "!=",
                .l_paren => "(",
                .r_paren => ")",
                .percent => "%",
                .l_brace => "{",
                .r_brace => "}",
                .l_bracket => "[",
                .r_bracket => "]",
                .dot => ".",
                .ellipsis2 => "..",
                .ellipsis3 => "...",
                .plus => "+",
                .plus_equal => "+=",
                .minus => "-",
                .minus_equal => "-=",
                .star_star => "**",
                .colon => ":",
                .slash => "/",
                .comma => ",",
                .ampersand => "&",
                .ampersand_equal => "&=",
                .angle_bracket_left => "<",
                .angle_bracket_left_equal => "<=",
                .angle_bracket_right => ">",
                .angle_bracket_right_equal => ">=",
                .tilde => "~",
                .keyword_and => "and",
                .keyword_else => "else",
                .keyword_error => "error",
                // .keyword_fn => "fn",
                .keyword_for => "for",
                .keyword_if => "if",
                .keyword_or => "or",
                // .keyword_while => "while",
                //TODO(tzelon): add missing tags
                else => "",
            };
        }

        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse switch (tag) {
                .invalid => "invalid token",
                .identifier => "an identifier",
                .string_literal => "a string literal",
                .eof => "EOF",
                .number_literal => "a number literal",
                // .doc_comment, .container_doc_comment => "a document comment",
                else => unreachable,
            };
        }
    };
};

pub const Scanner = struct {
    buffer: [:0]const u8,
    index: usize,
    line: usize,

    /// For debugging purposes.
    pub fn dump(self: *Scanner, token: *const Token) void {
        std.debug.print("{s} \"{s}\" -- {} \n", .{ @tagName(token.tag), self.buffer[token.loc.start..token.loc.end], token.loc });
    }

    pub fn init(source: [:0]const u8) Scanner {
        // Skip the UTF-8 BOM if present.
        return Scanner{ .buffer = source, .index = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) 3 else 0, .line = 1 };
    }

    const State = enum {
        start,
        expect_newline,
        identifier,
        string_literal,
        backslash,
        equal,
        bang,
        minus,
        star,
        slash,
        line_comment_start,
        line_comment,
        doc_comment_start,
        doc_comment,
        int,
        int_exponent,
        int_dot,
        float,
        float_exponent,
        ampersand,
        percent,
        plus,
        angle_bracket_left,
        angle_bracket_right,
        dot,
        dot_2,
        invalid,
    };

    pub fn next(self: *Scanner) Token {
        var result: Token = .{
            .tag = undefined,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };

        state: switch (State.start) {
            .start => switch (self.buffer[self.index]) {
                0 => {
                    if (self.index == self.buffer.len) {
                        return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    } else {
                        continue :state .invalid;
                    }
                },
                ' ', '\n', '\t', '\r' => {
                    self.index += 1;
                    result.loc.start = self.index;
                    continue :state .start;
                },
                '"' => {
                    result.tag = .string_literal;
                    continue :state .string_literal;
                },
                'a'...'z', 'A'...'Z', '_' => {
                    result.tag = .identifier;
                    continue :state .identifier;
                },
                '=' => continue :state .equal,
                '!' => continue :state .bang,
                '(' => {
                    result.tag = .l_paren;
                    self.index += 1;
                },
                ')' => {
                    result.tag = .r_paren;
                    self.index += 1;
                },
                '[' => {
                    result.tag = .l_bracket;
                    self.index += 1;
                },
                ']' => {
                    result.tag = .r_bracket;
                    self.index += 1;
                },
                ',' => {
                    result.tag = .comma;
                    self.index += 1;
                },
                ':' => {
                    result.tag = .colon;
                    self.index += 1;
                },
                '%' => continue :state .percent,
                '*' => continue :state .star,
                '+' => continue :state .plus,
                '<' => continue :state .angle_bracket_left,
                '>' => continue :state .angle_bracket_right,
                '{' => {
                    result.tag = .l_brace;
                    self.index += 1;
                },
                '}' => {
                    result.tag = .r_brace;
                    self.index += 1;
                },
                '~' => {
                    result.tag = .tilde;
                    self.index += 1;
                },
                '.' => continue :state .dot,
                '-' => continue :state .minus,
                '/' => continue :state .slash,
                '&' => continue :state .ampersand,
                '0'...'9' => {
                    result.tag = .number_literal;
                    self.index += 1;
                    continue :state .int;
                },
                else => continue :state .invalid,
            },

            .expect_newline => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index == self.buffer.len) {
                            result.tag = .invalid;
                        } else {
                            continue :state .invalid;
                        }
                    },
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    else => continue :state .invalid,
                }
            },

            .ampersand => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .ampersand_equal;
                        self.index += 1;
                    },
                    else => result.tag = .ampersand,
                }
            },

            .star => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .star_equal;
                        self.index += 1;
                    },
                    '*' => {
                        result.tag = .star_star;
                        self.index += 1;
                    },
                    else => result.tag = .star,
                }
            },

            .percent => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .percent_equal;
                        self.index += 1;
                    },
                    else => result.tag = .percent,
                }
            },

            .bang => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .bang_equal;
                        self.index += 1;
                    },
                    else => result.tag = .bang,
                }
            },

            .plus => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .plus_equal;
                        self.index += 1;
                    },
                    else => result.tag = .plus,
                }
            },

            .identifier => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => continue :state .identifier,
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
                    0x01...0x09, 0x0b...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .string_literal,
                }
            },

            .backslash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => result.tag = .invalid,
                    '\n' => result.tag = .invalid,
                    else => continue :state .invalid,
                }
            },

            .equal => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .equal_equal;
                        self.index += 1;
                    },
                    '>' => {
                        result.tag = .equal_angle_bracket_right;
                        self.index += 1;
                    },
                    else => result.tag = .equal,
                }
            },

            .minus => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .minus_equal;
                        self.index += 1;
                    },
                    else => result.tag = .minus,
                }
            },

            .angle_bracket_left => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .angle_bracket_left_equal;
                        self.index += 1;
                    },
                    else => result.tag = .angle_bracket_left,
                }
            },

            .angle_bracket_right => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '=' => {
                        result.tag = .angle_bracket_right_equal;
                        self.index += 1;
                    },
                    else => result.tag = .angle_bracket_right,
                }
            },

            .dot => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '.' => continue :state .dot_2,
                    else => result.tag = .dot,
                }
            },

            .dot_2 => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '.' => {
                        result.tag = .ellipsis3;
                        self.index += 1;
                    },
                    else => result.tag = .ellipsis2,
                }
            },

            .slash => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '/' => continue :state .line_comment_start,
                    else => result.tag = .slash,
                }
            },
            .line_comment_start => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    },
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    '/' => continue :state .doc_comment_start,
                    '\r' => continue :state .expect_newline,
                    0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .line_comment,
                }
            },
            .doc_comment_start => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => result.tag = .doc_comment,
                    '\r' => {
                        if (self.buffer[self.index + 1] == '\n') {
                            result.tag = .doc_comment;
                        } else {
                            continue :state .invalid;
                        }
                    },
                    '/' => continue :state .line_comment,
                    0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => {
                        result.tag = .doc_comment;
                        continue :state .doc_comment;
                    },
                }
            },
            .line_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            continue :state .invalid;
                        } else return .{
                            .tag = .eof,
                            .loc = .{
                                .start = self.index,
                                .end = self.index,
                            },
                        };
                    },
                    '\n' => {
                        self.index += 1;
                        result.loc.start = self.index;
                        continue :state .start;
                    },
                    '\r' => continue :state .expect_newline,
                    0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .line_comment,
                }
            },
            .doc_comment => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    0, '\n' => {},
                    '\r' => if (self.buffer[self.index + 1] != '\n') {
                        continue :state .invalid;
                    },
                    0x01...0x09, 0x0b...0x0c, 0x0e...0x1f, 0x7f => {
                        continue :state .invalid;
                    },
                    else => continue :state .doc_comment,
                }
            },
            .int => switch (self.buffer[self.index]) {
                '.' => continue :state .int_dot,
                '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                    self.index += 1;
                    continue :state .int;
                },
                'e', 'E', 'p', 'P' => {
                    continue :state .int_exponent;
                },
                else => {},
            },
            .int_exponent => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '-', '+' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    else => continue :state .int,
                }
            },
            .int_dot => {
                self.index += 1;
                switch (self.buffer[self.index]) {
                    '_', 'a'...'d', 'f'...'o', 'q'...'z', 'A'...'D', 'F'...'O', 'Q'...'Z', '0'...'9' => {
                        self.index += 1;
                        continue :state .float;
                    },
                    'e', 'E', 'p', 'P' => {
                        continue :state .float_exponent;
                    },
                    else => self.index -= 1,
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
        return result;
    }
};
