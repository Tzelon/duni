# Duni number literals

## The type system

User space has **one** numeric type: `number`. No `int`/`uint`/`i32`/`f64`
split, no signed-vs-unsigned, no fixed bit-width.

Inside the compiler there are **two comptime types** — `comptime_int`
(exact, arbitrary precision) and `comptime_float` (f64) — the Lua model: one
user-facing type, distinct internal representations. The split exists
because they are different math (exact vs IEEE) and because the InternPool's
index-equality invariant needs `1` and `1.0` to be different-typed values.
Both coerce into `number` at the runtime boundary; mixed comptime arithmetic
coerces int → float (see `notes/sema.md`).

> Supersedes an earlier version of this note that made floats a fully
> separate user-space type. What `number` lowers to at runtime (f64?
> error-on-overflow?) is still **the** open decision — today WatGen emits
> `i32` for int results / `f64` for float results as a placeholder and
> panics on ints that don't fit.

## Pipeline status — all three literal forms work end-to-end

```
"42"      → .int      Dir{ .int = u64 }          → comptime_int (u32 fast tag)
"2^100.." → .big_int  Dir{ .int_big, .str }      → comptime_int (limbs)
"3.14"    → .float    Dir{ .float = f64 }        → comptime_float
```

- `AstGen.numberLiteral` dispatches on `std.zig.parseNumberLiteral`.
- **Big ints**: limbs are parsed with `std.math.big`, serialized into
  `AstGen.string_bytes` (unaligned), referenced by the `str` data field where
  **`len` counts limbs, not bytes** (readers multiply by `@sizeOf(Limb)`).
  `Dir` carries `string_bytes`; `Sema.dirIntBig` copies limbs out (alignment)
  and interns. Storage in the pool: see `notes/intern_pool.md`.
- **Floats**: sign is folded into the constant at AstGen time.
  `negation` special-cases a direct number-literal operand and re-enters
  `numberLiteral` with `.negative` — for floats the sign goes into the value
  (preserving `-0.0`, which `negate`-as-`0 - x` would destroy); for ints the
  literal stays positive and a `negate` instruction carries the sign
  (`assert(isPositive())` in `addIntBig` depends on this).
- `-0` integer literal is **rejected** (`AnalysisFail`). Deliberate
  divergence from Zig (which allows it). `-0.0` is fine and distinct from
  `0.0`.
- Parenthesized operands break the literal fold: `-(3.14)` is a real
  `negate` instruction folded later by Sema (bit sign-flip for floats).

## Decisions made

- Integer `/` is **trunc division** (`intDivTrunc`); float `/` is IEEE
  division. Division by zero is a comptime error for both.
- `comptime_int → comptime_float` coercion rounds via `nearest_even`
  (lossy for > 2^53 — accepted, same as Zig's coercion).

## Open decisions

- **Float literal precision**: Zig round-trips f64↔f128 and refuses literals
  that don't fit f64 exactly; Duni currently parses as f128 and silently
  `@floatCast`s. `1.00000000000000001` quietly becomes `1.0`. Decide:
  error or accept-documented.
- **`number` runtime lowering** (see above).

## Error reporting

Interim: `std.log.warn` + `error.AnalysisFail` (warn, not err — the Zig test
runner fails any run that logs at error level). The real design —
structured errors accumulated on the Dir, rendered against source — is
`notes/astgen_error_reporting.md`, unbuilt.

## Tests

- AstGen: `expect(source, dir_dump)` string tests cover int / big int /
  float / all three negation shapes / `-0` rejection.
- Sema: `expectAnalyzed` (index-comparison) covers each literal kind plus
  arithmetic on them.
- Anything with tests must be referenced from `root.zig`'s `comptime` block
  or `zig build test` silently skips it (test collection follows analysis).
