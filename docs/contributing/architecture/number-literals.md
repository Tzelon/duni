# Number literals

How the three literal forms lower. The rules they implement are
[0007](../decisions/0007-one-numeric-type.md) (one numeric type, `number` =
f64) and [0008](../decisions/0008-exact-or-error-materialization.md) (exact
materialization or error).

## The three forms

```
"42"       → .int      Dir{ .int = u64 }        → comptime_int (u32 fast tag)
"2^100.."  → .int_big  Dir{ .int_big, .str }    → comptime_int (limbs)
"3.14"     → .float    Dir{ .float = f64 }      → comptime_float
```

`AstGen.numberLiteral` dispatches on `std.zig.parseNumberLiteral`.

**Big integers.** Limbs are parsed with `std.math.big` and serialized into
`AstGen.string_bytes` unaligned, referenced by the `str` data field where
**`len` counts limbs, not bytes** — readers multiply by `@sizeOf(Limb)`. `Dir`
carries `string_bytes`; `Sema.dirIntBig` copies the limbs out for alignment and
interns them. Pool storage is in [InternPool](./intern-pool.md).

**Floats.** The sign is folded into the constant at AstGen time. `negation`
special-cases a direct number-literal operand and re-enters `numberLiteral`
with `.negative`. For floats the sign goes into the value, preserving `-0.0`
which `negate`-as-`0 - x` would destroy. For integers the literal stays
positive and a `negate` instruction carries the sign — `addIntBig`'s
`assert(isPositive())` depends on that.

Parentheses break the fold: `-(3.14)` is a real `negate` instruction, folded
later by Sema with a bit sign-flip.

## Emission

A number is an `f64` in the emitted WAT, whatever form it was written in:

```
42     →  (func $main (result f64) f64.const 42 …)
7 / 2  →  (func $main (result f64) f64.const 3.5 …)
```

## Known inconsistency — `-0`

`AstGen.zig:301` rejects a negative-zero *integer* literal with
`error.AnalysisFail` and the log line `0 cannot be negative`. That rule
predates the decision that `number` is f64, under which `-0` is simply
`-0.0`. `test/cases/wat/negative_zero.duni` contains `-0` and expects
`f64.const -0`, so the case fails today. See
[0007](../decisions/0007-one-numeric-type.md) — the case is right and the rule
should go.

`-0.0` written as a float literal is accepted and is distinct from `0.0`.

## Errors

Interim: `std.log.warn` plus `error.AnalysisFail` — warn rather than err
because the Zig test runner fails any run that logs at error level. The real
design is [DP-0001](../proposals/0001-diagnostics.md).

## Tests

AstGen `expect(source, dir_dump)` string tests cover int, big int, float, all
three negation shapes, and `-0` rejection. Sema `expectAnalyzed` compares by
interned index and covers each literal kind plus arithmetic on them.

Anything with tests must be referenced from `root.zig`'s `comptime` block, or
`zig build test` silently skips it — test collection follows analysis.
