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
simple_value            (unused; index IS the value)    values
int_comptime_int_u32    the value itself                0 ..= u32.max
int_comptime_int_i32    @bitCast(i32 value)             i32.min ..= -1
int_positive            limbs index of `Int` header     > u64-range
int_negative            limbs index of `Int` header     < i64-range
float_comptime_float    extra index of `Float64`        any f64
int_u32                 the value itself                typed `u32`
int_i32                 @bitCast(i32 value)             typed `i32`
float_f64               extra index of `Float64`        typed `number`
string                  a `NullTerminatedString` handle strings
type_function           extra index of `TypeFunction`   function types
extern                  extra index of `Key.Extern`     host imports
```

The typed arms (`int_u32`, `int_i32`, `float_f64`) are no longer reserved —
`get` produces them for values whose type is a concrete `u32`/`i32`/`f64`
rather than a comptime type, and `typeOf` maps them to `u32_type`, `i32_type`,
and `f64_type`.

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
`string_type`, `zero`, `one`, `negative_one`. (Simple types must stay the
leading contiguous block — `indexToKey` decodes them positionally.) Pre-interned value statics make hot checks
O(1) index compares: `dirNegate` builds `0 - x` from `.zero` without
interning, and integer div-by-zero is `rhs.toIntern() == .zero`.

## String values — one handle type, not Zig's two

**Decision:** a comptime string value is `Key.string: NullTerminatedString` —
the same table-ordinal handle `getString` returns and the dedup map is keyed
by. One new `Tag.string` whose `data` is the handle. No `String {start, len}`
struct, no aggregate encoding. `string_type` joins the simple-type block of
the statics (before `zero`), extending the four-way correspondence above.

### Why one handle type

Zig's pool hands out **byte offsets** into `string_bytes`. A bare offset
leaves the question "where does the string end?" with two possible answers,
and each answer is a type:

```
Zig:  handle = byte position 6

  NullTerminatedString(6):        String(6) + external len:
    w o r l d 0                     w o r l d
    →→→→→→→→→ ^                    └─ len=5 ─┘
    walk until 0                    length stored elsewhere
```

Two incompatible contracts about the same buffer → two types.

Our handles are **row numbers in the `strings` boundary table**, and the end
always comes from the table — `toSlice` reads
`string_bytes[strings[i] .. strings[i+1] - 1]`, never scanning for `0`:

```
Duni:  handle = row 1

  strings table:   [0]=0   [1]=6   [2]=12
                     │       │       │
  string_bytes:    h e l l o 0 w o r l d 0
                   └── row 0 ──┘└── row 1 ──┘
```

One contract → one type. A second type would be a second name for the same
concept, paid for with conversions at every boundary (`getString`, the dedup
map, and `Key` all speak the ordinal). The trailing `0` is decoration so
`toSlice` can return `[:0]const u8` — it is *not* how length is known, so
embedded `NUL`s can't corrupt anything (today they're unrepresentable anyway:
the scanner rejects raw control characters and escapes don't exist yet).

### Equality is handle equality

`getString` dedupes bytes *before* a `Key` ever exists, so equal strings
share one handle — `hash64`/`eql` on `Key.string` compare the handle, never
the bytes. This is the core invariant (one index per canonical value)
extended to strings; do not "fix" `eql` to compare bytes.

### Why not Zig's aggregate encoding

In Zig, `"hello"` is `*const [5:0]u8` — there is no string type, so string
data is stored as an *array aggregate* (`Key.aggregate` with `bytes` storage)
and the literal's value is a pointer to it. Duni's `string` is a primitive,
Elixir-flavored opaque binary — not an indexable array of `u8`. A leaf value
is the honest encoding; importing aggregates would be Zig's premise without
Zig's language.

### When a second type would earn its place

Binary slicing (Elixir-style pattern matching on substrings): a substring's
`start`/`len` doesn't land on table boundaries, so a row number can't
describe it — *that* arc introduces a `{start, len}` type alongside the
ordinal, which is Zig's split arrived at when the language demands it.

## Why comptime_int / comptime_float (and not `number`)

User space has one numeric type, `number`. The compiler splits comptime
values into `comptime_int` (exact, arbitrary precision) and `comptime_float`
(f64) because they are *different math* — exactness vs IEEE — and because the
index-equality invariant would break if `1` and `1.0` were same-type values
at different indexes. `number` appears later, at the runtime boundary, as the
type both comptime kinds coerce into. Its WASM lowering is undecided; the
pool stays target-independent — only WatGen knows about wasm types.

## Function types — the `func_type` key (2026-08-14)

`Key.FuncType = { param_types: Index.Slice, return_type: Index }`. The param
list is variable-length, so it's stored inline in `extra` and referenced by a
`Index.Slice` (`{start, len}` — a stripped `Nav`-free version of Zig's
`Index.Slice`, no `tid` since Duni is single-threaded). The Slice exists for
**lifetime**: a decoded `Key.FuncType` returned by `indexToKey` must survive
later `extra` growth, so it holds offsets, not a raw slice into `extra` that
would dangle on realloc. `.get(ip)` re-derives the live slice on demand.

Interning goes through a dedicated `getFuncType`, **not** the generic
`get(Key)`. The generic path hashes/dedups the key *before* writing storage,
but you can't build a `Slice`-based probe key until the params are already in
`extra` (chicken-and-egg). So `getFuncType` uses Zig's **add-then-revert**:
write the header + params unconditionally, build the Slice key over what you
just wrote, `getOrPut`, and on a hit rewind `extra.items.len` to abandon the
speculative write. `get(Key)` has `.func_type => unreachable`.

Rule that falls out: a value whose fields are all fixed-width handles rides
the generic `get(Key)` (string, int, float, **extern**); a value with a
variable-length trailing array needs a dedicated `getX` + add-then-revert
(func_type). See `funcTypeReturnType` for the minimal single-threaded decode
(no `unwrap`/shard machinery, no `type_pointer` branch — Duni has neither).

## Extern values — `Key.Extern`

`Key.Extern = { name, ty, lib_name }` — the wasm import name, its `func_type`,
and the import module (`OptionalNullTerminatedString`, `.none` → `"host"`).
All three are fixed-width handles, so it's a leaf value on the generic
`get(Key)` path; `Key.Extern` is its own `extra` layout (no separate `Tag`
struct). This is Duni's whole "callable decl" representation — Zig's `Nav`
(the decl-level slot with lazy/incremental/namespace/backend/generic
machinery) is deliberately **not** ported. Reasoning + revival trigger:
a deferred decision (Sema / InternPool). The extern's `name` duplicates the
`Sema.decls` key on purpose — the value must stand alone for WatGen to emit
`(import "host" "print" …)` without the decl map.

## Type and Value — newtypes over `Index` (2026-08-14)

Both types and values are one `InternPool.Index`. `Value.zig` wraps that with
value-only methods; `Type.zig` is its type-only counterpart (Zig's exact
split). **The InternPool itself stays raw `Index`** — `Key.*.ty`,
`FuncType`'s fields, `getFuncType`, `isIntegerType`, `InternPool.typeOf` all
speak `Index`. `Type`/`Value` wrap **above** the pool (Sema / Air / WatGen),
converting at the boundary (`Type.fromInterned` out, `.toIntern()` in). This
is forced: `Type` imports `InternPool`, so the pool can't reference `Type`
without a cycle — same reason Zig keeps its InternPool in raw `Index`.

`typeOf` therefore lives in two places: `InternPool.typeOf(index) -> Index`
(pure key-switch: a value → its `.ty`; a type → `type_type`), and
`Air.typeOf(ref) -> Type` which wraps it for the interned case and derives
the type from the instruction tag for the runtime case. The runtime arm is
the seam for the S3/S4 Air instruction set (`.arg`/`.call`) — it can't be
designed until those instructions exist.
