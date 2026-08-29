# 0007: One numeric type, `number`, semantically f64

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-29

## Context

Every statically-typed language faces the same request: give me an integer
type, or several. `i32`/`u64`/`f32` are what systems programmers expect, and a
compiler that folds arbitrary-precision integers at comptime is halfway to
offering them.

The alternatives were a runtime-tagged number (Erlang, Grain), a compile-time
int/float dual representation carried to runtime, or the Lua/JavaScript model
of a single double.

## Decision

User space has **one** numeric type: `number`, semantically an IEEE 754
double. No `int`/`uint`/`i32`/`f64` split, no signed-versus-unsigned, no fixed
widths. Integer-valued numbers are doubles that happen to be integral.

Inside the compiler there are two comptime types — `comptime_int` (exact,
arbitrary precision) and `comptime_float` (f64). They are internal: both
coerce to `number` at the runtime boundary, and mixed comptime arithmetic
coerces int to float via `nearest_even`. The split exists because exact and
IEEE math are different math, and because the InternPool's index-equality
invariant needs `1` and `1.0` to be different-typed values.

## Consequences

`number` is `f64` everywhere in the ABI, so no function boundary needs to ask
which numeric representation it received. Runtime-tagged integers would turn
every `+` into a runtime call on WASM; a dual representation collapses to f64
at every boundary anyway.

Two user-visible rules follow and are not separately negotiable:

- **`/` is always IEEE division.** `5 / 2` is `2.5`, verified against the
  compiler today. Integer division belongs in explicit `div`/`rem` library
  functions, not in the operator.
- **Integral numbers print without a fractional part** — `8 / 2` prints `4`,
  not `4.0`, the JavaScript convention. This affects emitted WAT and test
  expectations.

The cost is exactness: contiguous exact integers only up to 2^53. That is
fenced by [0008](./0008-exact-or-error-materialization.md), which turns
inexact materialization into an error rather than silent drift, and by a
future low-level-types arc (`i32`/`i64`/`u32`/`u64`/`f32`) for code that needs
real integer semantics. The InternPool already carries `int_u32`, `int_i32`,
and `float_f64` tags for it.

**Known contradiction.** The note this record supersedes rejects a negative
zero *integer* literal (`AstGen.zig:301`, "0 cannot be negative"), a
deliberate divergence from Zig. But `test/cases/wat/negative_zero.duni`
contains `-0` and expects `f64.const -0`, and under this decision an integer
literal is a double, so `-0` naturally means `-0.0`. The rejection predates
`number` = f64. The case currently fails; the rule and the case must be
reconciled, and this record's position is that the case is right.

**Revisit if:** a real program needs exact integers beyond 2^53 and the
low-level types arc is not enough. The answer then is more explicit types, not
a second default numeric type.
