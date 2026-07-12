# InternPool

Canonical storage for comptime values and types, modeled on Zig's InternPool.
Shared by Sema and WatGen; owned by `main`. A `Value` is nothing but an
`InternPool.Index` — all comparisons, folding, and codegen work on indexes.

## The core invariant

**One index per canonical value.** Two values of the same type are equal iff
their indexes are equal. Everything below exists to protect this invariant;
everything above (Sema folding, `zero`-static comparisons, test assertions)
exists to exploit it.

## Key vs Item vs Tag

- `Key` is the *semantic* view — what callers construct and receive:
  - `simple_type: SimpleType`
  - `int: { ty, storage: u64 | i64 | big_int }`
  - `float: { ty, storage: f64 }`
- `Item` is the *stored* view: `{ tag: u8, data: u32 }` — 5 bytes per value.
- `Tag` picks the encoding. Many tags map to one Key variant; a tag encodes
  *how it's packed*, not what it means.

```
tag                     data means                      value class
──────────────────────  ──────────────────────────────  ─────────────────
simple_type             (unused; index IS the type)     types
int_comptime_int_u32    the value itself                0 ..= u32.max
int_comptime_int_i32    @bitCast(i32 value)             i32.min ..= -1
int_positive            limbs index of `Int` header     > u64-range
int_negative            limbs index of `Int` header     < i64-range
float_comptime_float    extra index of `Float64`        any f64
int_u32/int_i32/float_f64  reserved, no producer — `unreachable` in decode
```

## Encode funnels down, decode narrows up

`get` stores the smallest representation that fits, no matter which storage
variant the key arrived in — a `.big_int` key holding `7` becomes an
`int_comptime_int_u32` item. `indexToKey` reverses: even limb-stored values
come back as `.u64`/`.i64` when they fit; `.big_int` storage only appears for
values outside both.

Consequence: **round-tripping does not preserve the storage variant, only the
value.** That's why hashing and equality canonicalize (below), and why arith
code can intern raw big-int results without narrowing them first.

## Big ints: the limbs buffer

`int_positive`/`int_negative` data indexes into a dedicated
`limbs: ArrayList(Limb)` buffer (not `extra` — no u32/u64 alignment fight).
At that index sits a packed header occupying exactly one limb:

```
limbs:  ... │ Int{ty, limbs_len} │ limb0 (LSB) │ limb1 │ ...
              ▲ item.data points here
```

Decode uses the `[runtime_start..][0..comptime_len].*` re-slice pattern to
load the header as a fixed-size array and `@bitCast` it back.

**Lifetime caveat:** a decoded `.big_int` key borrows `ip.limbs` memory. Any
later `get` may realloc it. Rule: decode → use → drop; never hold a decoded
big-int key across another `get`.

## hash64 / eql — canonicalization is mandatory

The same number can be probed as `.u64` or `.big_int` (arith interns raw
big-int results). So:

- `hash64` canonicalizes ints through `toBigInt` (a stack `BigIntSpace`) and
  hashes ty + sign + limbs. Floats hash their **bit pattern**.
- `eql` is a storage matrix: scalar/scalar via `==` (mixed-sign compare is
  correct in Zig), scalar/big via `orderAgainstScalar`, big/big via
  `BigIntConst.eql` (contents, not slice pointers — `std.meta.eql` is wrong
  here and was a real dedup bug).
- Floats compare by **bits**, matching the hash: `0.0` and `-0.0` are two
  distinct interned values (they behave differently: `1/±0.0 = ±inf`), and
  identical-bit NaNs dedup (value `==` would intern endless NaN duplicates).

The pool stores *representations*, not mathematical values.

## Statics — the four-way correspondence

The first entries of `Index` are pre-interned by `init` from `static_keys`,
and mirrored, 1:1 in the same order, in **four places**:

```
InternPool.Index  ↔  InternPool.static_keys  ↔  Dir.Inst.Ref  ↔  Air.Inst.Ref
```

`static_len` is derived from `Dir.Inst.Ref`'s field count, so a mismatch is a
compile error — but the *order* correspondence is on you. Getting it wrong is
silent (an `Index` name pointing at the wrong interned value).

Current statics: `comptime_int_type`, `comptime_float_type`, `f64_type`,
`zero`, `one`, `negative_one`. Pre-interned value statics make hot checks
O(1) index compares: `dirNegate` builds `0 - x` from `.zero` without
interning, and integer div-by-zero is `rhs.toIntern() == .zero`.

## Why comptime_int / comptime_float (and not `number`)

User space has one numeric type, `number`. The compiler splits comptime
values into `comptime_int` (exact, arbitrary precision) and `comptime_float`
(f64) because they are *different math* — exactness vs IEEE — and because the
index-equality invariant would break if `1` and `1.0` were same-type values
at different indexes. `number` appears later, at the runtime boundary, as the
type both comptime kinds coerce into. Its WASM lowering is undecided; the
pool stays target-independent — only WatGen knows about wasm types.
