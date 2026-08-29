const std = @import("std");
const assert = std.debug.assert;

const TokenIndex = @import("../Ast.zig").TokenIndex;

const Node = @This();

tag: Tag,
main_token: TokenIndex,
data: Data,

pub const Tag = enum {
    /// The root node which is guaranteed to be at `Node.Index.root`.
    ///
    /// The `main_token` field is the first token for the source file.
    /// The `data` field is `extra_range`: the top-level statements.
    root,

    /// The `data` field is unused.
    ///
    /// Most identifiers will not have explicit AST nodes, however for
    /// expressions which could be one of many different kinds of AST nodes,
    /// there will be an identifier AST node for it.
    identifier,

    /// The `data` field is unused.
    number_literal,

    /// `true` / `false` — which one is recovered from the `main_token`
    /// (a `keyword_true` or `keyword_false` token). The `data` field is
    /// unused.
    bool_literal,

    /// The `data` field is unused.
    ///
    /// The `main_token` field is the string literal token.
    string_literal,

    /// `lhs + rhs`. The `main_token` field is the `+` token.
    add,

    /// `lhs - rhs`. The `main_token` field is the `-` token.
    sub,

    /// `lhs * rhs`. The `main_token` field is the `*` token.
    mul,

    /// `lhs / rhs`. The `main_token` field is the `/` token.
    div,

    /// `-expr`. The `main_token` field is the `-` token.
    negation,

    /// `lhs == rhs`. The `main_token` field is the `==` token.
    equal_equal,

    /// `lhs != rhs`. The `main_token` field is the `!=` token.
    bang_equal,

    /// `lhs < rhs`. The `main_token` field is the `<` token.
    less_than,

    /// `lhs <= rhs`. The `main_token` field is the `<=` token.
    less_or_equal,

    /// `lhs > rhs`. The `main_token` field is the `>` token.
    greater_than,

    /// `lhs >= rhs`. The `main_token` field is the `>=` token.
    greater_or_equal,

    /// `lhs and rhs`, short-circuit. The `main_token` field is the `and` token.
    bool_and,

    /// `lhs or rhs`, short-circuit. The `main_token` field is the `or` token.
    bool_or,

    /// `!expr`. The `main_token` field is the `!` token.
    bool_not,

    /// `lhs = rhs`. The `main_token` field is the `=` token.
    assign,

    /// `{a b}`.
    ///
    /// The `data` field is a `.extra` that stores a `ExtraIndex` to `Block`
    ///
    /// The `main_token` field is the `{` token.
    block,

    /// `a(b, c, d)`.
    ///
    /// The `data` field is a `.node_and_extra`:
    ///   1. a `Node.Index` to the function expression.
    ///   2. a `ExtraIndex` to a `Call`
    ///
    /// The `main_token` field is the `(` token.
    call,

    /// Extern function declarations use the fn_proto tags rather than this one.
    ///
    /// The `data` field is a `.node_and_node`:
    ///   1. a `Node.Index` to `fn_proto_*`.
    ///   2. a `Node.Index` to function body block.
    ///
    /// The `main_token` field is the `fn` token.
    fn_decl,

    /// `fn (a: b, c: d) return_type`.
    ///
    /// The `data` field is a `.extra_and_opt_node`:
    ///   1. a `Node.ExtraIndex` to `FnProto`.
    ///   2. a `Node.OptionalIndex` to the return type expression. Can't be
    ///      `.none` unless a parsing error occured.
    ///
    /// The `main_token` field is the `fn` token.
    ///
    /// Extern function declarations use this tag.
    fn_proto,

    /// `(expr)`.
    ///
    /// The `data` field is a `.node_and_token`:
    ///   1. a `Node.Index` to the sub-expression
    ///   2. a `TokenIndex` to the `)` token.
    ///
    /// The `main_token` field is the `(` token.
    grouped_expression,

    /// `if cond { then }` — no `else`; the whole expression types as void.
    ///
    /// The `data` field is a `.node_and_node`:
    ///   1. a `Node.Index` to the condition expression.
    ///   2. a `Node.Index` to the then block.
    ///
    /// The `main_token` field is the `if` token.
    if_simple,

    /// `if cond { then } else { els }` — the else branch may also be
    /// another `if` (else-if chains).
    ///
    /// The `data` field is a `.node_and_extra`:
    ///   1. a `Node.Index` to the condition expression.
    ///   2. a `ExtraIndex` to an `If`.
    ///
    /// The `main_token` field is the `if` token.
    if_else,
};

pub const Data = union {
    node: Index,
    node_and_node: struct { Index, Index },
    node_and_token: struct { Index, TokenIndex },
    node_and_extra: struct { Index, ExtraIndex },
    extra_and_opt_node: struct { ExtraIndex, OptionalIndex },
    extra_range: SubRange,
    extra: ExtraIndex,
};

pub const Index = enum(u32) {
    root = 0,
    _,

    pub fn toOffset(base: Index, destination: Index) Offset {
        const base_i64: i64 = @intFromEnum(base);
        const destination_i64: i64 = @intFromEnum(destination);
        return @enumFromInt(destination_i64 - base_i64);
    }

    pub fn toOptional(index: Index) OptionalIndex {
        const result: OptionalIndex = @enumFromInt(@intFromEnum(index));
        assert(result != .none);
        return result;
    }
};

/// Index into `nodes`, or null.
pub const OptionalIndex = enum(u32) {
    root = 0,
    none = std.math.maxInt(u32),
    _,

    pub fn unwrap(oi: OptionalIndex) ?Index {
        return if (oi == .none) null else @enumFromInt(@intFromEnum(oi));
    }

    pub fn fromOptional(oi: ?Index) OptionalIndex {
        return if (oi) |i| i.toOptional() else .none;
    }
};

/// A relative node index.
pub const Offset = enum(i32) {
    zero = 0,
    _,

    pub fn toOptional(o: Offset) OptionalOffset {
        const result: OptionalOffset = @enumFromInt(@intFromEnum(o));
        assert(result != .none);
        return result;
    }

    pub fn toAbsolute(offset: Offset, base: Index) Index {
        return @enumFromInt(@as(i64, @intFromEnum(base)) + @intFromEnum(offset));
    }
};

/// A relative node index, or null.
pub const OptionalOffset = enum(i32) {
    none = std.math.maxInt(i32),
    _,

    pub fn unwrap(oo: OptionalOffset) ?Offset {
        return if (oo == .none) null else @enumFromInt(@intFromEnum(oo));
    }
};

pub const ExtraIndex = enum(u32) { _ };

pub const SubRange = struct {
    /// Index into extra_data.
    start: ExtraIndex,
    /// Index into extra_data.
    end: ExtraIndex,
};

pub const FnProto = struct {
    params_start: ExtraIndex,
    params_end: ExtraIndex,
    /// Needed to make lastToken() work.
    rparen: TokenIndex,
};

pub const Call = struct {
    args_start: ExtraIndex,
    args_end: ExtraIndex,
    /// Needed to make lastToken() work.
    rparen: TokenIndex,
};

pub const Block = struct {
    expressions_start: ExtraIndex,
    expressions_end: ExtraIndex,
    /// Needed to make lastToken() work.
    rbrace: TokenIndex,
};

pub const If = struct {
    then_expr: Index,
    else_expr: Index,
};
