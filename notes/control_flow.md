# Duni — Control Flow Design Notes

Arc 2: booleans, comparisons, `if`/`else`, `and`/`or`. Decisions locked
2026-08-27 with the user; the seams arc (`notes/type_system.md` §8) landed
first and this arc builds on them.

## Decisions

1. **`if` syntax:** `if cond { a } else { b }` — if-as-expression with
   block branches, no parens around the condition (a parenthesized
   condition still parses, but only as an ordinary grouping expression).
   Replaces grammar.y's C-style `if (expr) statement`; grammar.y updated.
2. **`else` is optional; an else-less `if` types as `void`.** The
   then-branch must itself be `void` (Rust's rule) — a value-producing
   body without `else` is a compile error, never a silent discard. This
   falls out of the branch rule below: an else-less `if` is exactly
   `else { void }`.
3. **Branch type rule:** the `if`'s result type is
   `unify(then_ty, else_ty)`; mismatch is a compile error located at the
   `if`. First real consumer of the arc-1 `unify` seam (so `number`
   branches mix freely — `comptime_float`/`f64` already unify).
4. **Comparisons are numbers-only** (`==` `!=` `<` `<=` `>` `>=`), result
   `Bool`. A non-numeric operand gets the arithmetic-shaped "invalid
   operands to binary expression" diagnostic. String equality belongs to
   the strings arc (its comparison semantics are an open question there).
5. **Logical operators are the keywords `and` / `or`, negation is `!`.**
   Short-circuit. Operands must be `Bool` — no truthiness; a non-Bool
   operand is a compile error.

## Semantics

- `if` is an expression. Branches are blocks; a block's value is its last
  expression (existing blocks-are-expressions rule). Else-if chains are
  just an `else` branch whose body is another `if`.
- **Comptime-fold rule (Zig semantics):** a comptime-known condition
  analyzes *only the taken branch*, inline — the untaken branch is never
  analyzed, so an error inside it is not reported. No Air `block` is
  emitted; the `if` folds to the taken branch's value.
- A runtime condition emits the structured-Air path below. The condition
  must unify with `Bool`.

## Bool

- `Bool` is a new primitive: `bool_type`, `bool_true`, `bool_false` land
  in `Dir.Inst.Ref` **and** `InternPool.Index`/`static_keys`/
  `SimpleType`/`SimpleValue` at the same numeric positions (`resolveInst`
  depends on the two enums staying identical).
- **Runtime representation: wasm `i32`, values 0/1.** Wasm comparison ops
  on f64 (`f64.eq/ne/lt/le/gt/ge`) already yield i32. Consequence:
  locals are no longer all f64 — `collectLocals` records a wasm type per
  local (`(local i32)` vs `(local f64)`).
- Host printing of Bool is out of scope (parking lot): the run cases
  print numbers derived from branches instead.

## The merge model (runtime `if`)

Air grows structured bodies — the substrate `match` compilation and
`return_call` plug into later:

- `block`: result type + trailing body; its result is the merge point.
- `cond_br`: condition operand + two trailing bodies.
- `br`: target block + operand — a value-carrying jump to the block's
  merge point.

AstGen lowers `if` to Zig's shape: a `block` wrapping the condition and a
`condbr(cond, then_body, else_body)`; each body ends with a `break` to the
enclosing block carrying that branch's value. Sema's runtime path analyzes
each Dir body into an Air body (per-body instruction collection, Zig's
`block.instructions` scratch pattern); the Dir `break` becomes an Air `br`.
This is `Block.Merges` at Duni scale: one merge point, value-carrying brs.

WatGen lowers structurally: an Air `block`'s result is a wasm local;
`br` = `local.set <block result>` + `br <label>`; `cond_br` = wasm
`if … else … end`. Labels are depth-relative — a block-depth stack maps
Air block inst → current relative depth.

## `and` / `or` lowering

Short-circuit is branching, so both ride on the `if` machinery (Zig's
`bool_br` strategy, without a dedicated instruction — a dedicated Dir tag
is a later compaction if profiles care):

- `a and b` → `if a { b } else { false }`
- `a or b` → `if a { true } else { b }`

Operands unify against `bool_type`; a non-Bool operand is a compile error.
The golden proof of short-circuit is a side effect that must not happen
(`false and print(1) == 1` prints nothing).

## Stage plan

- **Stage A** — Bool statics, scanner keywords/tokens, comparison
  parsing/lowering, `dirCmp` (fold + runtime Air), WatGen i32 story.
  `and`/`or` are rejected with a diagnostic until Stage C.
- **Stage B** — `if`/`else`, Dir `condbr`, structured Air
  (`block`/`cond_br`/`br`), Sema runtime block path, WatGen recursive
  `writeBody`.
- **Stage C** — `and`/`or` on Stage B's machinery.

One commit per stage; full suite green before each.
