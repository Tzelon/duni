# Duni internal memory layout & calling convention

## Two ABIs, not one

Duni has (will have) two distinct ABIs, and conflating them is the mistake
this note exists to prevent:

- **Internal ABI** — how Duni-compiled code calls Duni-compiled code inside
  one core module. Direct calls, pointers into our own linear memory, zero
  copies. We own it completely and can change it any time; it is never
  observable from outside.
- **Boundary ABI** — how the module talks to a host or to other components.
  This is the WASM Component Model's **Canonical ABI**: shared-nothing,
  lift/lower with copy semantics at the edge. Not implemented yet; when it
  is, it will be thin thunks in WatGen wrapped around *exported* functions
  only (plus a `cabi_realloc` export). Nothing internal changes.

The copying that components do is intentional isolation between memories —
it only ever happens at the edge. No language uses the Canonical ABI for its
own internal calls, and neither do we.

## Two doors: tight embedding vs. component boundary

Componentization is **packaging, not compilation**. WatGen emits one
artifact — a core module — and every deployment picks one of two doors
into it:

```
                ┌────────── component wrapper (wasm-tools, later) ─────────┐
                │  lifted exports; cabi_realloc thunk; memory HIDDEN       │
                │  ┌──────────── core module (what WatGen emits) ───────┐  │
component host ─┼─►│  exports:                                          │◄─┼─ tight host
(wasmtime, jco) │  │    memory                                          │  │  (bespoke glue,
COPIES at edge  │  │    alloc / free       (internal allocator)         │  │   knows Duni layouts)
                │  │    raw fns            (internal ABI)               │  │  ZERO-COPY
                │  └────────────────────────────────────────────────────┘  │
                └──────────────────────────────────────────────────────────┘
```

- **Tight door** (custom embedding): the host sees the exported linear
  memory as one buffer and reads `(ptr, len)` results in place; for
  host→guest data it calls the exported `alloc` and writes directly.
  Zero-copy both directions. This door exists from day one — it is just
  the core module's exports.
- **Component door**: the wrapper hides memory and raw exports and adds
  lift/lower thunks. The edge copy here is not ABI overhead — it is the
  physical fact of *two memories*. Our side is free (internal layout ==
  canonical layout, `(ptr, len)` passes through unchanged); the copy is
  the receiver lifting into its own memory, which no ABI can remove.
- **Resources — zero-copy *inside* the component model.** For big data
  that must cross a real component boundary, don't pass the value: export
  a WIT `resource`, pass the `i32` handle, keep the data in Duni memory,
  and let consumers call methods on it. Composes with RC — the resource
  table entry holds a reference; dropping the handle decrements.

Prior art check (Roc's wasm backend): Roc keeps its native model on wasm —
the module **imports** `roc_alloc`/`roc_realloc`/`roc_dealloc` from `env`
and shares a layout contract with a bespoke host (tight coupling only; no
component story). Duni inverts the arrow: the allocator is internal and
**exported**, which serves a tight host equally well *and* keeps the
component door open. What Roc's import gives that we drop — host-swappable
allocation policy — comes back as exported policy controls (e.g. an
arena-reset export a server host calls between requests).

Discipline this imposes: the core module's raw exports are a **stable
contract** for tight hosts. Once one exists, internal-ABI changes to
exported functions are breaking changes for it — Roc's version-locking,
but scoped to hosts that chose the tight door.

## North star: match the canonical memory layout

The Canonical ABI defines, for every interface type, an exact in-memory
representation (size, alignment, field offsets) used when values live in
linear memory. **Duni's internal layout adopts that representation as its
default.** Rationale:

- The layout decisions (string repr, variant packing, alignment algorithm)
  are hard-won and already specified precisely — no need to re-derive them.
- If our internal layout *is* the canonical layout, the future boundary
  thunks become near-trivial: lowering a Duni string is passing two i32s;
  the only unavoidable copy is the *other* side lifting into its own memory.

Reference: the Canonical ABI explainer in the component-model repo
(`design/mvp/CanonicalABI.md`) — the `alignment`, `elem_size`, and
flattening algorithms there are the normative source.

## Layout rules

Pointer size: wasm32, so pointers and lengths are `i32`. (memory64 would
change this everywhere; parked, see open questions.)

- **`number`** — IEEE 754 f64. Size 8, align 8. Passed as a wasm `f64`.
  (See `notes/number_literals.md`; the future explicit low-level types
  `i32`/`i64`/`u32`/`u64`/`f32` map 1:1 to their wasm scalar.)
- **`string`** — `(ptr: i32, len: i32)`, `len` in bytes, UTF-8, no null
  terminator, no header. In memory: 8 bytes, align 4, ptr at offset 0.
  This is exactly the canonical repr and exactly what WatGen emits today
  (see `notes/string_literals.md`).
- **Lists/arrays** (future) — `(ptr, len)` like string; elements
  contiguous, stride = element size rounded up to element alignment.
- **Records/structs** (future) — fields laid out in declared order, each
  field aligned to its own alignment; struct alignment = max field
  alignment; struct size rounded up to struct alignment. No field
  reordering. (Canonical ABI rule. If we ever want size-optimizing
  reordering, that is an internal-only optimization and must be undone in
  the boundary thunk — decide then, not by accident.)
- **Variants / tagged unions** (future) — discriminant first: smallest of
  `u8`/`u16`/`u32` that fits the case count; then padding to the max
  payload alignment; then payload storage sized for the largest case.
  Alignment = max(discriminant, payloads). This covers `option`-like and
  `result`-like types too — the Canonical ABI's *despecialization* insight:
  `option<T>`, `result<T,E>`, `bool` are all just variants; `tuple` is just
  a record. Internally there is a tiny core of layout formers (scalar,
  record, variant, list) and everything else maps onto them.
- **Opaque host resources** (future) — `i32` handles indexing a table, not
  raw pointers. Matches canonical `resource` and keeps host objects out of
  our memory entirely.

## Calling convention (flattening)

Aggregates are decomposed into scalar params instead of passing through
memory, following the canonical flattening algorithm:

- A param of record/variant type flattens field-by-field into core scalars
  (a string becomes two `i32` params), up to **16 flat params** per call;
  beyond that, the whole argument list spills to memory and one pointer is
  passed. Same threshold as the Canonical ABI, so exported functions need
  no re-marshaling of params at the boundary.
- **Returns: deliberate internal divergence.** The Canonical ABI allows
  only 1 flat return (spilling to a caller-provided return pointer beyond
  that) because it predates reliable multi-value. Core wasm has multi-value
  and WatGen already uses it — `main` returns a string as a `(ptr, len)`
  result pair. Internally we return up to N flat results via multi-value;
  the future boundary thunk adapts exported functions to the 1-flat-return
  + retptr rule. Cheaper for every internal call, adaptation cost only at
  the edge.

## Memory management: reference counting, the Roc model

Duni manages heap values with **reference counting, not a tracing GC**.
Direction, not yet implemented — recorded here so allocation work builds
toward it.

Why RC over GC here:

- **Immutability makes plain RC sound.** Duni data is immutable; a value
  can only reference values that already exist, so the reference graph is a
  DAG — cycles are impossible and no cycle collector is needed. This is a
  **language invariant, not an accident**: if Duni ever adds mutable
  references to heap values, cycles become possible and plain RC leaks.
  Any such feature must revisit this note first.
- **WASM economics.** A tracing collector must be shipped inside every
  module and needs root-finding that core wasm makes hard (no stack
  introspection — shadow stacks or root spilling). RC is inc/dec/free — a
  tiny runtime. Wasm is single-threaded today, so counts are non-atomic
  and cheap.
- **Deterministic frees** — memory returns at the last decrement, no
  pauses, predictable footprint. The one trade: dropping a large structure
  frees recursively at that moment, a latency spike GC would amortize.

Decisions that follow:

- **Refcount header lives *before* the pointer** (Roc stores it at
  `ptr - 8`); the pointer itself points at the data. Layouts above are
  untouched — `string` stays `(ptr, len)` and boundary lowering stays
  near-free. The header is an allocation detail, never a type-layout
  detail.
- **Constants are immortal.** Values in `(data ...)` segments cannot be
  freed; a reserved refcount value marks them so decrements are no-ops.
- **Naive first, Perceus later.** Day one is plain inc/dec everywhere —
  correct but chatty. The known fix is Perceus-style static RC (Koka/Lean,
  what Roc does): elide ops for borrowed values, and reuse/mutate in place
  when the count is provably 1 (functional API, imperative performance).
  That is a Sema-level analysis to grow into, not a runtime change.
- **Boundary interplay**: after a lift copies a value out at the component
  edge, `post-return` is where the source's decrement belongs.

### The allocator

- **Lives inside the module, written in Duni** (`lib/allocator.duni` or
  similar), built on the only genuine compiler primitives: raw load/store
  and `memory.grow`. Same shape as Zig's std allocators. Not host-provided
  (see the Roc contrast above) — internal calls stay direct, and the
  component door needs a guest-side `cabi_realloc` anyway, which becomes a
  thin wrapper over this.
- **Ambient and invisible to users.** There is one current allocator per
  module; the *compiler* inserts allocation, `inc`, and `dec` calls when
  lowering heap-producing operations. User code never mentions memory —
  no Zig-style allocator threading through signatures. The only people who
  see the allocator are the stdlib author and the compiler.
- **Policy is swappable at the Duni level** (general-purpose vs. arena),
  selected per module, with host-facing policy controls as plain exports
  (arena reset etc.) rather than host-provided functions.

## What this means for WatGen today

Nothing changes: `f64` scalars and `(ptr, len)` string pairs are already
conformant. The rules above are the contract new types must follow as
structs/variants/lists arrive in Sema and WatGen.

## Open questions

- **Allocator implementation.** Placement and ambience are decided (see
  "The allocator"); the algorithm itself is not — malloc-style free lists
  vs. size classes vs. bump-with-reset for the arena policy. Also which
  raw-memory primitives the compiler exposes to `lib/allocator.duni`, and
  how they're spelled.
- **Seamless slices** (Roc trick worth stealing when runtime strings/lists
  arrive): a tag bit in the capacity field marks "points into someone
  else's allocation — don't free through me", enabling copy-free
  substrings/sub-lists. Interacts with RC: a slice must keep its backing
  allocation alive, so the bit redirects inc/dec to the original
  allocation's header.
- **WasmGC.** Superseded as a direction by the RC decision above; kept
  only as the escape hatch if RC's invariants ever break (e.g. mutable
  heap references). Components-over-GC is still settling upstream anyway.
- **memory64.** Would widen ptr/len to `i64`. No decision needed until a
  use case appears; the rules are stated in terms of "pointer-sized" where
  possible.
- **Strings crossing the boundary.** Canonical lifting requires valid
  UTF-8. We must decide whether Duni guarantees UTF-8 at string
  construction (making lowering free) or validates at the boundary. Leaning
  construction-time — see the encoding TODO in `notes/string_literals.md`.
