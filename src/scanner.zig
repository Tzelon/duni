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
        indentifier,
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
                '0'...'9' => {
                    result.tag = .number_literal;
                    self.index += 1;
                    continue :state .number;
                },
                '-' => {
                    self.index += 1;
                    result.tag = .minus;
                },
                else => continue :state .invalid,
            },
            .indentifier => unreachable,
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
            => true,
            else => false,
        };
    }
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct { start: usize, end: usize };

    pub const Tag = enum {
        identifier,

        // Literals.
        number_literal,

        // Operators tokens.
        equal,
        plus,
        minus,
        asterisk,
        slash,

        // End
        invalid,
        eof,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .identifier,
                .eof,
                .number_literal,
                => null,

                .equal => "=",
                .plus => "+",
                .minus => "-",
                .asterisk => "*",
                .slash => "/",
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
}
