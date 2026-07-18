# TODO — next: scopes & variables

Goal: `x = 1; y = x + 2; y * 3` lowers end-to-end. Names die in AstGen —
DIR only ever sees refs (`notes/name_resolution.md`).

## Decisions (made)

- [x] **Rebinding.** Allowed, Elixir-style: a rebind pushes a new `LocalVal`
      that shadows the old one — no redeclaration check. The only
      name-resolution error is "use of undeclared identifier".
      (`notes/name_resolution.md` updated.)
- [x] **Statement separator.** Newline, auto-inserted Go-style: the scanner
      emits `.newline` only when the previous token can end an expression
      (`endExpression`: identifier, number_literal, r_paren, string_literal).
- [x] **Bind syntax.** `=` is a Pratt infix at `prec_assignment`,
      right-associative (`a = b = c` is `a = (b = c)`), producing a **form**
      (main_token `=`, args `[lhs, rhs]`) — NOT a new closed node tag.
      `=` is a **binding (match)**, not assignment: the lhs is a pattern,
      so the parser accepts any expression there and never validates it.
      Node kinds stay the closed set from `notes/ast_structure.md`; operators
      are the open layer inside forms, which is what the future macro system
      builds on. (`grammar.y` updated.)

## Pipeline work, in order

1. **Scanner** — DONE: `identifier` scanning (with trailing `!`/`?`), `=`,
   keyword map (`fn`), `.newline` insertion driven by `insert_newline` +
   `endExpression`, `.string_literal` state (inert until the strings arc);
   all covered in the `tokenizer` test.
2. **Parse** — root becomes a statement list: loop expressions separated by
   `.newline` (skip blanks, resync-to-newline on error), collect via
   `scratch` → `listToSpan`, root data holds the `SubRange`. Wire the
   `.identifier` prefix rule (leaf node, like `number`). Wire `.equal`
   infix (`Parse.bind`): like `binary` but rhs parsed at the SAME
   precedence (right-assoc). No lhs validation — lhs is a pattern.
   Builds a `form` (op `.equal`), no new node tag.
3. **AstGen** — the heart (`notes/zir.md` §5–6, stripped Zig design):
   - `Scope` chain: `top` → `gen_dir` → `local_val` variants; lookup walks
     parent links, first match wins.
   - `identAsString` — intern names (reuse `string.zig`'s
     `NullTerminatedString` machinery).
   - `bind` arrives as a `form` whose main_token is `=` — a new arm in the
     `formExpr` dispatch, not a new AST tag. The lhs is a pattern: today
     only `.identifier` is supported, anything else is an AstGen
     "unsupported pattern" error (pattern matching comes later). Lower rhs,
     push `LocalVal{ name → inst }`. Because `=` is an expression, keep
     `current_scope: *Scope` as mutable state on AstGen (not threaded
     return values) so nested binds like `(x = 1) + x` work.
   - `identifier`: chain lookup → return the *existing* ref. Identifiers
     emit no instruction.
   - Misses: "use of undeclared identifier" — the only name-resolution
     error now that rebinding is allowed. Wants real error reporting —
     decide whether phase 1 of `notes/astgen_error_reporting.md` (minimal
     accumulation) rides along.
4. **Dir** — likely no new tags: names are erased before DIR. (`decl_val`
   only arrives with namespaces/containers later.)
5. **Sema** — unchanged: refs into `inst_map` already resolve.
6. **Tests** — AstGen `expect` dumps for bind/lookup/shadowing; Sema
   `expectAnalyzed` for `x = 1; x + 2` folding to 3.

## Still open from the numbers arc

- AstGen error reporting (`notes/astgen_error_reporting.md`) — now blocking
  good errors here too (undeclared identifier).
- `number` runtime lowering decision — WatGen's i32/f64-by-value and its
  "does not fit i32" panics are placeholders.
- Float literal precision: restore Zig's f64 round-trip check or document
  accept-with-rounding.

## Quality follow-ups (no behavior change)

- `dirDiv` duplicates `dirArithmetic` body — extract or fold back.
- `Expend` → `Expand` typo in `dirDiv` comment.
- `if (maybe_lhs_val) |v|` nesting → `orelse return error.AnalysisFail`.
- `inst_map.putAssumeCapacity` → `putAssumeCapacityNoClobber`.
- Reserved tags `int_u32`/`int_i32`/`float_f64` have no producer — drop or
  implement with sized types.
- Trim stale `ty` mentions in `arith.add/sub/mul/div` doc comments.

## Parked

- Parens excluded from spans — TODO(tzelon) on `Parse.grouping` (LSP).
- Runtime values → real Air instructions → WatGen arithmetic.
- Strings: unsupported at every layer (`notes/string_literals.md`).
