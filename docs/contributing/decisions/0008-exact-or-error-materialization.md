# 0008: Comptime integers materialize exactly, or error

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-29

## Context

Comptime arithmetic in Duni is arbitrary precision, and runtime `number` is an
f64 ([0007](./0007-one-numeric-type.md)). Something must happen when an exact
comptime integer becomes a runtime value it cannot represent.

Three options: silently round, reject beyond a fixed threshold such as 2^53,
or reject exactly those values f64 cannot represent.

## Decision

Lowering a `comptime_int` to a runtime `number` is a compile error unless f64
represents the value **exactly**. No threshold, no rounding.

The check is Zig's `coerceExtra` fits test: round the integer to f64, round it
back through a big integer with `setFloat(.nearest_even)`, compare. Any
magnitude with 53 or fewer significant bits passes. Implemented in
`Sema.coerce` / `coerceIntToFloat`.

Float *literals* are the deliberate exception: a float literal means "the
nearest f64", silently. `1.00000000000000001` is `1.0`, as in JavaScript and
Elixir.

## Consequences

`2^53` and `2^64` compile — they are exactly representable. `2^53 + 1` and
`2^64 + 1` do not. That is more permissive than a "≤ 2^53" threshold, which
would wrongly reject exact values, and stricter than rounding, which loses
them quietly.

Comptime arithmetic stays arbitrary precision throughout; only the boundary to
a runtime value is checked. An intermediate result may exceed f64's range as
long as what lands in a runtime value does not.

The check gave the compiler its destination-typed coercion seam, which the
low-level-types arc extends, and it replaces the two "does not fit" panics
WatGen used to have with a real diagnostic.

Rejecting a float literal for imprecision was considered and declined: testing
binary exactness rejects `3.14` and `0.1` too, and Zig itself never rejects —
its `comptime_float` is f128 and the check only picks a storage format.

**Revisit if:** exact-integer programs become common enough that the error is
noise rather than a guardrail. The fix would be the low-level types, not
silent rounding.
