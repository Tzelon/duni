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
> separate user-space type.

At runtime, **`number` is semantically IEEE 754 f64** — the JS model (see
"Decisions made"). Devs who need real integer semantics or a specific width
drop to the explicit low-level types (`i32`/`i64`/`u32`/`u64`/`f32`), a
later arc (the reserved `int_u32`/`int_i32`/`float_f64` InternPool tags are
parked for it). Today WatGen still emits `i32` for int results / `f64` for
float results as a placeholder and panics on ints that don't fit — that
code predates this decision and must catch up.

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

- **`number` = f64.** One user-facing runtime type, semantically an IEEE 754
  double. Integer-valued numbers are doubles that happen to be integral.
  Rationale: runtime-tagged integers (Erlang, Grain) turn every `+` into a
  runtime call on WASM; a compile-time int/float dual repr collapses to f64
  at every function boundary anyway. The cost — contiguous exact integers
  only up to 2^53 — is fenced by the low-level-types escape hatch. ABI:
  `number` is `f64` everywhere.
- **`/` is always IEEE division**: `5 / 2` → `2.5`. Explicit `div`/`rem`
  Kernel functions cover integer division later. *Supersedes* the earlier
  "integer `/` is trunc division" decision; `intDivTrunc` must go.
- **Exact or error at materialization — no threshold**: comptime stays
  arbitrary precision; lowering a `comptime_int` to runtime `number` is a
  Sema error unless f64 represents the value *exactly*. The check is Zig's
  `coerceExtra` fits check (round the int to f64, round-trip back through a
  big int via `setFloat(.nearest_even)`, compare): any magnitude with ≤ 53
  significant bits passes — `2^53` and `2^64` are fine, `2^53 + 1` and
  `2^64 + 1` error. (An earlier draft said "|x| ≤ 2^53"; that is only the
  *contiguous* exact range and wrongly rejects exact values like `2^64`.)
  Implemented: `Sema.coerce` / `coerceIntToFloat`, the Zig-shaped
  destination-typed coercion seam the low-level types arc extends. Replaces
  both WatGen "does not fit" panics with a real diagnostic.
- **Float literal precision — accept with rounding, the JS way**: a float
  literal means "the nearest f64", silently — `1.00000000000000001` is
  `1.0`, same as JavaScript and Elixir. Documented behavior, not a bug; no
  check in AstGen. (An earlier draft said "restore Zig's f64↔f128
  round-trip check" — that check tests *binary* exactness, which almost no
  decimal has: it rejects `3.14` and `0.1` too. Zig itself never rejects;
  its comptime_float is f128 and the check only picks a storage format.
  The alternative — error iff the shortest form of the literal's f64
  denotes a different decimal than written — was considered and declined.)
- **Integral numbers print without a fractional part**: `8 / 2` prints `4`,
  not `4.0` — the JS convention. Affects WatGen text output and test
  expectations.
- Division by zero is a comptime error.
- `comptime_int → comptime_float` coercion rounds via `nearest_even`
  (lossy for > 2^53 — accepted, same as Zig's coercion).

## Open decisions

- Low-level types arc: surface syntax for `i32`/`i64`/`u32`/`u64`/`f32`,
  their arithmetic semantics (overflow behavior), and `number` ↔ low-level
  conversions.

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
