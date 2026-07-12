# AstGen

## What it is

AstGen is the compiler pass between Parse and Sema. It walks the AST that
Parse produced and lowers it into a flat, untyped IR called DIR.

AstGen:
- Walks every AST node, emits zero or more DIR instructions.
- Parses literal token text into actual values (`"42_2"` → `u64(422)`).
- Erases syntax-only constructs (parentheses, etc.).
- Resolves identifiers to instruction references — see `name_resolution.md`.
- Detects shadowing / redeclaration errors.
- Reports compile errors with source locations — see `astgen_error_reporting.md`.
- Manages per-block instruction lists via a `GenDir` scope stack — see `zir.md`.

It does **not**:
- Decide types — Sema's job.
- Evaluate comptime — Sema's job.
- Read the source bytes after the literal-parsing step.

## Where it lives

```
  Parser        AstGen         Sema         Codegen
    │            │              │             │
    ▼            ▼              ▼             ▼
   AST   ────► DIR  ──────►   AIR  ───────► machine code
         (untyped, flat)    (typed)
```

Input: an `Ast` (tree of nodes + tokens + `extra_data`).
Output: a `Dir` (flat array of `Inst { tag, data }` + side arrays).

## How it works

One entry point per AST node tag — a single `expr` function dispatching on
`Ast.Node.Tag`. Each handler does its small piece of work, then recurses
into children. Children's results come back as `Inst.Ref` values, which the
parent uses as operands.

```
expr(node):
    switch (tree.nodeTag(node)) {
        .number_literal     => numberLiteral(node)   // emits .int or .float
        .add                => binOp(node, .add)     // emits .add
        .grouped_expression => expr(child)           // returns child's Ref
        .identifier         => lookup in scope       // returns existing Ref
        .bind               => bindDecl(node)        // emits rhs, pushes scope
        .block              => block(node)           // opens GenDir, emits .block
        ...
    }
```

The walk is structural: it follows the AST's parent-child shape, threading
a `Scope` chain for name lookups and a `GenDir` for "which instructions
belong to this lexical block."

## Example 1 — literal

Source: `42`

```
AST                       AstGen action                  DIR
─────────────────        ──────────────────────────     ─────────────────────
.number_literal    ──►   parse "42" → u64(42)     ──►   %0 = int 42
                         emit Inst.int
```

## Example 2 — syntax-only node erased

Source: `(42)`

As implemented, parens are erased one stage *earlier* than this note first
planned: `Parse.grouping` returns the inner expression's node directly, so
there is no `grouped_expression` AST node at all and AstGen never sees the
parens. Consequence: source spans stop at the inner expression (`-(1 + 2)`
reports a span without the `)`), and a TODO(tzelon) on `Parse.grouping`
covers restoring paren tokens (a grouped node storing `r_paren`, Zig-style)
when the LSP needs exact spans.

## Example 3 — binding + name resolution

Source: `x = 1; x + 2`

```
AST                       AstGen action                  DIR
─────────────────        ──────────────────────────     ─────────────────────
.bind (x = 1)      ──►   lower rhs → %0                 %0 = int 1
                         push LocalVal "x" → %0
.add               ──►   lower lhs (.identifier "x")
                         scope lookup → %0 (reuse)
                         lower rhs (.number_literal 2)   %1 = int 2
                         emit .add                       %2 = add %0 %1
```

Final DIR is one flat list with no AST and no names:

```
%0 = int 1
%1 = int 2
%2 = add %0 %1
```

## Errors

Design (not built yet — see `notes/astgen_error_reporting.md`): AstGen
records a diagnostic against a token (and optionally an offset within the
token) and either:

- Continues, leaving a sentinel in place of the bad value — recoverable.
- Aborts the current expression with `error.AnalysisFail` — unrecoverable.

Errors travel out alongside DIR, the same way Parse's errors travel
alongside the AST.

Interim reality: error sites (`-0`, unparseable literal) do
`std.log.warn` + `error.AnalysisFail`. Warn, not err, because the Zig test
runner fails any run that logs at error level — tests exercising error
paths would fail a green suite.

## What "untyped" means

DIR records that a value exists and how it was produced. It does **not**
record what type the value has. `%0 = int 42` says "instruction 0 is an
integer literal with value 42" — not "instruction 0 has type `number`."
Attaching types is Sema's job.

This separation is what makes DIR cheap to share across multiple Sema runs
(e.g. instantiating a generic) without re-lowering the AST every time.
