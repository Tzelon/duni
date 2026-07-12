# AST structure — homoiconic shape over a small Zig enum

This note covers the AST layout decision for Duni: why operators are *not* Zig
enum variants, what the trade-offs look like in memory, and what the concrete
node / form layout looks like in the DoD representation.

## What Elixir's AST looks like

Elixir is uniformly a 3-tuple `{name, meta, args}`, with one carve-out: a few
literal kinds self-represent.

```elixir
# self-representing literals
42          # => 42
:foo        # => :foo
"hi"        # => "hi"
[1, 2]      # => [1, 2]
{a, b}      # 2-tuples self-represent

# everything else is {name, meta, args}
1 + 2       # => {:+,  [...], [1, 2]}
foo(a, b)   # => {:foo, [...], [a_ast, b_ast]}
if c, do: a, else: b
            # => {:if, [...], [c_ast, [do: a_ast, else: b_ast]]}

# variables are distinguished from a 0-arg call by the 3rd slot:
x           # => {:x, [ctx: nil], nil}  ← variable: 3rd slot is `nil`
x()         # => {:x, [...], []}        ← call:     3rd slot is `[]`
```

`name` is an **atom** — an interned symbol from an open universe. Anyone can
mint `:defmodule`, `:unless`, `:my_macro`; no compiler change. `meta` is a
keyword list (source line, hygiene context, etc.). `args` is a list of child
ASTs.

## Two layers: kind vs operator

It's tempting to read "the tag can be anything" and reach for a non-exhaustive
Zig enum. That conflates two layers:

- **Layer 1 — node kind.** Finite, closed: `{ int_lit, float_lit, str_lit,
  symbol, form }`. There will never be a 6th kind. This is the Zig `Tag` enum,
  and it stays closed and small so the rest of the compiler can `switch`
  exhaustively.
- **Layer 2 — form operator.** Open: `+`, `if`, `defmodule`, `my_macro`,
  anything. This is what Elixir's `name` atom is. It does **not** live in the
  Zig enum at all — it lives as an interned-symbol (`StrId`) inside `.form`
  data.

Same split Elixir already has; Elixir just hides layer 1 inside the runtime's
tuple-shape check.

## Why operators can't be Zig enum variants

You technically can. The design rejects it for one hard reason and several
corollaries.

**Zig enums are fixed at compile time.** All variants must be written in source
before `zig build`. Non-exhaustive enums (`enum(u32) { ..., _ }`) let *any u32*
be a legal value, but the *named* set is still closed. You can do
`@enumFromInt(42)` but there's no `.foo_macro` variant until someone edits the
enum.

**Macros add operators at runtime / user-comptime.** When a user writes:

```duni
defmacro unless(cond, body) = quote(if !cond then body)
```

`unless` is now a legal head of a form. The compiler binary shipped six months
ago has to handle a form whose operator is `unless` — a name it has never
heard of. If the operator is a Zig enum variant, you can't represent that node,
because no `.unless` variant exists. End of design.

Corollaries:

- **Quote / unquote.** `quote(foo(1,2))` builds an AST value at comptime. If
  `foo` had to be an enum variant, every user-defined function name would need
  a corresponding variant — impossible.
- **Macro pattern-matching.** Elixir matches `{:if, _, [c, [do: a, else: b]]}`
  — a uniform tuple match. If the operator is an enum variant, matching
  becomes "is the kind `.if_stmt`?" — and you've baked the entire language
  grammar into the enum. That's Nim's `NimNodeKind` (`nnkIfStmt`,
  `nnkWhileStmt`, `nnkInfix`, …), which is the verbose path the design is
  trying to avoid.
- **Exhaustiveness cost.** A 200-variant `Tag` means every `switch (tag)` in
  lowering, sema, printing has 200 arms or an `else =>`. With the 5-kind
  split, every switch is 5 arms and operator-specific logic lives in one place
  (a symbol-table lookup), not scattered through every visitor.
- **It's just string interning in disguise.** If you went non-exhaustive and
  used `@enumFromInt(intern_id)`, you've reinvented `StrId` with worse
  ergonomics — the named variants become decoration over an integer key, and
  you still need a side table mapping ids back to names.

## Memory layout trade-offs

Three layouts worth comparing. Take a `MultiArrayList(Node)` with
`Node = { tag: u8, main_token: u32, data: 8B }` — 13 B/node, no padding
(columns are separate arrays).

### Approach A — fat enum (`.add`, `.if_stmt`, …)

`1 + 2` is 3 nodes:

```
[add, int_lit(1), int_lit(2)] + extra=∅       → 39 B
```

Dispatch: load `tag[i]` → `.add`. **1 load.**

### Approach B — 5-kind + operator-as-child-symbol-node

`1 + 2` is 4 nodes + 3 extra_data entries:

```
[form, symbol, int_lit(1), int_lit(2)] + extra=[sym_idx, lhs_idx, rhs_idx]
                                                52 B + 12 B = 64 B
```

Dispatch ("is this a `+`?"): tag[i]=form → data[i]=children_range →
extra[range.start]=child_idx → tag[child_idx]=symbol → data[child_idx]=StrId →
compare to StrId("+"). **~5 dependent loads.**

Rule of thumb across a real AST: B is **~1.3-1.5× the node count** of A, plus
the indirection cost during sema.

### Approach B′ — operator as `StrId` field inside the form node

This is what Elixir actually does: store the operator as an *atom inline* in
slot 1 of the tuple — not as a separate child node. Translated to DoD:

```zig
data: union { ..., form: struct { op: StrId, args: ExtraIndex } }
```

`1 + 2` → 3 nodes (form, int_lit(1), int_lit(2)) + 2 extra_data entries → ~43 B.
Dispatch is 2 loads (tag → data.form.op).

B′ is roughly the same footprint as A while keeping the operator open. The
cost: it stops being "uniformly, everything is a node." A call on an arbitrary
expression (`(get_fn())()`, `obj.method()`) needs a special case — the
operator there is a sub-AST, not a symbol. Elixir does this too: atom in slot
1 for the simple case, a 3-tuple in slot 1 for the `foo.bar(...)` case.

### Does any of it matter?

For Duni's target (embeddable, comptime-rich, WASM): almost certainly no.
Compilers spend ~5% of time in AST traversal and 95% in sema / typecheck /
codegen / optimization. 1.5× the AST size on a 10K-line program is microseconds
of extra scan time. The handoff parks this: *"the AST is unlikely to bottleneck
a small embedded language."*

The escape hatch — if profiling ever flags it — is to specialise the hot
operators back into the closed `Tag` enum (`.add`, `.if_stmt`, …) while
keeping `.form` as the fallback. Macros still see the homoiconic shape through
the accessor seam; only consumers that care about perf switch on the
specialised tags. You don't have to choose forever.

## Recommended layout (B′ with escape hatch)

Fits the existing `Node = { tag, main_token, data }`, `MultiArrayList(Node)`
shape:

```zig
pub const Tag = enum(u8) {
    root,        // data.extra
    int_lit,     // data.int
    float_lit,   // data.float
    str_lit,     // data.str
    symbol,      // data.symbol
    form,        // data.form     — op is an interned name (common case)
    form_dyn,    // data.form_dyn — op is an arbitrary expression
};

pub const Data = union {           // 8 bytes (largest variant wins)
    int: i64,
    float: f64,
    str: StrId,                    // u32
    symbol:   Symbol,              // 8 B
    form:     Form,                // 8 B
    form_dyn: FormDyn,             // 8 B
    extra:    ExtraIndex,          // u32 — for root / sub-ranges
};

pub const Symbol = packed struct {
    name: StrId,                   // u32
    ctx:  HygieneCtx,              // u32 — Elixir-style ctx id
};

pub const Form = packed struct {
    op:   StrId,                   // u32 — interned operator (e.g. "+", "if")
    args: ExtraIndex,              // u32 — points at SubRange in extra_data
};

pub const FormDyn = packed struct {
    callee: Node.Index,            // u32 — sub-AST for (get_fn())(x), obj.m(x)
    args:   ExtraIndex,            // u32
};

pub const SubRange = struct { start: ExtraIndex, end: ExtraIndex };
```

Children live in `extra_data`, indirected through a 2-word `SubRange`:

```
extra_data[form.args + 0] = start
extra_data[form.args + 1] = end
extra_data[start .. end]  = Node.Index per child
```

### Worked example — `1 + foo(2)`

```
nodes:
  [0] root      main_token=0           data.extra  = 0
  [1] form      main_token=1 ("+")     data.form   = { op=#"+",   args=2 }
  [2] int_lit   main_token=0           data.int    = 1
  [3] form      main_token=3 ("foo")   data.form   = { op=#"foo", args=6 }
  [4] int_lit   main_token=5           data.int    = 2

extra_data:                            // u32 entries
  [0..2]   SubRange for root  : { start=10, end=11 }
  [2..4]   SubRange for node 1: { start=12, end=14 }
  [6..8]   SubRange for node 3: { start=14, end=15 }
  [10]     Node.Index = 1               (root's only top-level expr)
  [12..14] Node.Index = 2, Node.Index = 3   (+'s args: 1, foo(2))
  [14]     Node.Index = 4               (foo's only arg: 2)
```

Layout in `extra_data` doesn't have to be in any particular order — the parser
just appends records as it goes.

## Why this shape

- **Common case is flat.** A named call / operator (`+`, `if`, `foo(...)`)
  reads the op as a single `StrId` field inside the form node — no
  child-symbol-node, no extra dereference. That's the perf win over
  operator-as-child-node.
- **Escape hatch is honest.** When the callee really is an expression
  (`(get_fn())(x)`, `obj.m(x)`), tag the node `.form_dyn` and the callee is
  just a `Node.Index`. Macros and consumers learn from the tag which to read.
- **Args are uniform.** Both `.form` and `.form_dyn` use the same
  `args: ExtraIndex → SubRange → [Node.Index]` machinery — one set of
  accessors for child iteration.
- **Hygiene fits naturally.** `symbol.ctx` is a `u32` Elixir-style context id.
  Two symbols are the same variable iff `(name, ctx)` match — keyed in name
  resolution.

## What goes into `.form` vs a closed tag

The principle: **a node is `.form` if a user could write a macro that matches
or synthesizes it.** Closed tags are for nodes that don't carry a meaningful
operator name — literals, syntax-only nodes, structural roots.

Two questions decide it:

1. **Does it have an operator name?** A token or keyword that names *what's
   being done*: `+`, `if`, `unless`, `defmacro`, `foo` (as a call). If yes →
   form.
2. **Could a user reasonably redefine or pattern-match it?** A macro overriding
   `+` for strings. A user writing `defmacro unless(...)`. A match on
   `{:if, _, _}`. If yes → must be form.

Both "no" → closed tag.

### Examples

| Construct                | Form or closed                              | Why                                                         |
| ------------------------ | ------------------------------------------- | ----------------------------------------------------------- |
| `42`, `"hi"`, `:foo`     | closed `.number_literal` / `.string_literal` / `.atom` | Self-representing literals. No operator atom.    |
| `(expr)`                 | closed `.grouped_expression`                | Syntax-only. Gone after AstGen.                             |
| `root`                   | closed `.root`                              | Structural. Not user-visible.                               |
| `1 + 2`                  | form `op=:plus, args=[1, 2]`                | Operator atom; macros redefine `+`.                         |
| `-x`                     | form `op=:minus, args=[x]`                  | Same atom as binary minus, arity 1.                         |
| `foo(a, b)`              | form `op=:foo, args=[a, b]`                 | Named call.                                                 |
| `if cond then a else b`  | form `op=:if, args=[cond, a, b]`            | `if` is a macro target.                                     |
| `x = 1`                  | form `op=:=, args=[x, 1]`                   | Assignment macros.                                          |
| `obj.field`              | form `op=:., args=[obj, :field]`            | Field access is a form in Elixir.                           |
| `[1, 2, 3]`              | closed `.list_literal`                      | Self-representing in Elixir. No atom.                       |
| `{a, b, c}` (3-tuple)    | form `op=:{}, args=[a, b, c]`               | Elixir split: 2-tuples self-represent, ≥3 are forms.        |

### Judgment calls

A few don't have a single right answer — choose with your eyes open:

- **Identifiers (`foo` as a variable).** Closed `.identifier` is what most
  compilers do. Elixir uses `{:foo, meta, nil}` (form with `args=nil`
  distinguishes variable from call). Closed is simpler today; migrate when
  hygiene + variable-name macro matching become real needs.
- **Blocks (`{ stmt; stmt; }`).** Closed `.block` is easy. Form `op=:block,
  args=stmts` lets `quote do ... end` construct blocks naturally. Either
  works.
- **Function declarations (`fn foo(x): int { ... }`).** Form (`op=:fn`,
  args = `[name, params, return_type, body]`) lets `fn` itself be macro-
  redefined. Closed `.fn_decl` is the simpler walker. Default to form for a
  macro-heavy language.

When unsure, default to form. "Wrong toward form" costs a slightly bigger
walker arm. "Wrong toward closed" breaks macros six months from now.

### The "quote" mental test

If `quote(expr)` would produce a form, the AST node for `expr` should *be* a
form. If quoting produces a value, store a closed literal.

- `quote(1 + 2)` → `{:plus, _, [1, 2]}` → form
- `quote(42)` → `42` (self-represents) → closed
- `quote((1 + 2))` → `{:plus, _, [1, 2]}` (parens vanish) → grouped is closed
- `quote(if x do y end)` → `{:if, _, [...]}` → form

The AST shape matches what macros see.

## Why this works: parser vs AstGen split

The form node lets the parser stay agnostic about meaning. The pipeline cleanly
separates two responsibilities:

- **Parser owns *shape*.** Tokenize input, validate syntax, use precedence /
  associativity to fix tree topology. It records the operator atom *as
  written* in the form node — it does not decide what `+` does, who `foo`
  refers to, or whether `unless` exists. Precedence carries no semantic
  weight; it only determines which subexpression is whose child.
- **AstGen owns *meaning*.** Resolve operator atoms to concrete Dir
  instructions (`:plus` arity 2 → `.add`; arity 1 → identity), resolve
  identifiers via the scope chain, expand macros, erase syntax-only nodes,
  parse literal text into values.

```
text
 │
 ▼
[Scanner]      what characters were used
 │ tokens
 ▼
[Parser]       what shape was written, with operator atoms intact
 │ AST (form nodes carry :plus, :minus, ...)
 ▼
[AstGen]       what does each name resolve to; what op should run
 │ Dir (.add, .sub, refs)
 ▼
[Sema]         what type does each value have
 │ Air (typed)
 ▼
[WatGen]       what target instructions to emit
```

Each stage strips one form of ambiguity:

- Parser strips ambiguous precedence.
- AstGen strips ambiguous identity (names → refs, atoms → semantic ops).
- Sema strips ambiguous type.

Two AST nodes with identical shape can mean different things — the meaning is
decided later, by AstGen against the scopes and macro table at that point in
the walk. That late binding is what makes macros possible: the AST is a
faithful record of what was written, not what it does.

This is why Dir tags are **semantic** (`.add`, `.sub`, `.mul`, `.div`,
`.neg`) while form `op` atoms are **lexical** (`:plus`, `:minus`, `:star`,
`:slash`). Seeing `:plus` in Dir or `:add` on a form node means something
leaked across an abstraction boundary.

## Alternative if uniformity is more important than the StrId compression

A single `.form` whose `op` is always a `Node.Index` and the callee is a child
node. Everything is a node, no `.form_dyn` split. Cost: an extra `symbol` node
per named call (the Approach B math: ~1.3× nodes).
