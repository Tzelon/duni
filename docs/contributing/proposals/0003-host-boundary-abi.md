# Host boundary ABI

- **Proposal:** [DP-0003](0003-host-boundary-abi.md)
- **Status:** pitch
- **Date:** 2026-08-29
- **Implementation:** partial — today's emitted module already conforms
- **Decision record:** none

## Introduction

Duni has two ABIs, and conflating them is the mistake this proposal exists to
prevent:

- **Internal ABI** — how Duni code calls Duni code inside one core module.
  Direct calls, our own linear memory, zero copies. We own it and may change it
  at any time; it is never observable from outside.
- **Boundary ABI** — how the module talks to a host. This is the WASM Component
  Model's **Canonical ABI**: shared-nothing, lift and lower with copy semantics
  at the edge.

The proposal is to adopt the canonical layout rules as the internal layout too,
so the boundary costs nothing, and to write those rules down before structs,
lists, and variants each pick a layout by accident.

## Motivation

WatGen already emits a boundary. A string-valued program produces linear
memory, an exported `memory`, a data segment, and a multi-value `(i32, i32)`
return — that is the tight-embedding door, working today, whether or not
anyone decided it.

What does not exist is the rule set. The next three types to arrive — records,
lists, variants — each need a layout, and a layout chosen per-feature is a
layout that has to be renegotiated with every host later. Field order, padding,
and the discriminant's width are not the kind of thing to decide inside a
`switch` arm at 2am.

Adopting the Canonical ABI's rules answers all of them in advance, from a
specification that has already argued through the edge cases.

## Could this be done in Duni?

Split, and the split is deliberate:

- **Compiler:** layout rules, the flattening algorithm, and what WatGen emits.
  These are code generation.
- **Duni:** the allocator. It lives inside the module and is written in Duni
  (`lib/allocator.duni`), exported as `alloc`/`free` for the tight door. The
  compiler calls it, but does not implement it — the same relationship it has
  with every other library function ([0003](../decisions/0003-no-built-ins.md)).

## Proposed solution

**One artifact, two doors.** Componentization is packaging, not compilation.
WatGen emits a core module; each deployment picks a door:

```
                ┌────── component wrapper (wasm-tools, later) ──────┐
                │  lifted exports; cabi_realloc; memory HIDDEN      │
                │  ┌──────── core module (what WatGen emits) ─────┐ │
component host ─┼─►│  exports: memory, alloc/free, raw fns        │◄┼─ tight host
COPIES at edge  │  └──────────────────────────────────────────────┘ │  ZERO-COPY
                └──────────────────────────────────────────────────-┘
```

The **tight door** exists from day one — it is just the core module's exports.
A host reads `(ptr, len)` results in place and calls `alloc` to write data in.
Zero copy in both directions.

The **component door** is a later wrapper that hides memory and adds lift/lower
thunks. Its edge copy is not ABI overhead; it is the physical fact of two
memories, and no ABI removes it.

## Detailed design

Pointers and lengths are `i32` (wasm32).

**Layout rules.**

| Type | Representation |
| --- | --- |
| `number` | IEEE 754 f64. Size 8, align 8. Passed as a wasm `f64`. |
| `string` | `(ptr: i32, len: i32)`, `len` in bytes, UTF-8, no null terminator, no header. In memory 8 bytes, align 4, ptr at offset 0. |
| list *(future)* | `(ptr, len)` like string; elements contiguous, stride = element size rounded up to element alignment. |
| record *(future)* | Fields in declared order, each aligned to its own alignment. Struct alignment = max field alignment; size rounded up to that. **No field reordering.** |
| variant *(future)* | Discriminant first — smallest of `u8`/`u16`/`u32` that fits the case count — then padding to max payload alignment, then storage for the largest case. |
| host resource *(future)* | An `i32` handle indexing a table, never a raw pointer. Host objects stay out of our memory. |

The canonical *despecialization* insight is worth stating explicitly:
`option<T>`, `result<T, E>`, and `bool` are all variants; a tuple is a record.
Internally there is a small core of layout formers — scalar, record, variant,
list — and every other type maps onto them.

**Flattening.** Aggregates decompose into scalar parameters rather than passing
through memory: a record flattens field by field, a string becomes two `i32`
params, up to **16 flat params** per call. Beyond that the argument list spills
to memory and one pointer is passed. Same threshold as the Canonical ABI, so
exported functions need no re-marshaling.

**Returns — a deliberate internal divergence.** The Canonical ABI allows one
flat return, spilling to a caller-provided return pointer beyond that, because
it predates reliable multi-value. Core wasm has multi-value and WatGen already
uses it: `main` returns a string as an `(i32, i32)` pair. Internally we return
up to N flat results; the future boundary thunk adapts exported functions to
the one-return-plus-retptr rule. Cheaper for every internal call, with the
adaptation cost paid only at the edge.

**Zig's answer.** Zig's wasm backend has its own C-ABI-shaped lowering and no
notion of the Component Model. This is a place where Duni's target diverges
from the reference implementation, so the Canonical ABI spec is the authority
here rather than `src/arch/wasm/CodeGen.zig`.

## Effect on existing programs

None. `f64` scalars and `(ptr, len)` string pairs already conform — the rules
describe what WatGen does today and constrain what it does next.

## Effect on the host boundary

This proposal *is* the host boundary. What it fixes in place:

- Linear memory is exported. A tight host may read it directly.
- Strings cross as `(ptr, len)`, not as handles or copies.
- `alloc`/`free` become part of the exported surface once an allocator exists.
- Field order in records is source order, permanently — a host may hardcode
  offsets.

## Testing

`test/cases/wat/` is the right flavor for all of it: the emitted shape is
precisely the claim. One golden per layout former as it lands — a record's
field offsets and padding, a variant's discriminant width, a call that spills
past 16 flat params.

The `run/` cases prove the other half: a host reading what the rules promise.

## Future directions

- **Component wrapper** — `wasm-tools component new` over the core module,
  plus a `cabi_realloc` export. Packaging work, not compiler work.
- **Seamless slices** — a tag bit in the capacity field marking "points into
  someone else's allocation, don't free through me", enabling copy-free
  substrings. Interacts with reference counting: a slice must keep its backing
  allocation alive.
- **memory64** — would widen ptr and len to `i64`. The rules above are stated
  in terms of pointer size where possible, so this stays a substitution.

## Open questions

- **Where UTF-8 validity is guaranteed** — at construction or at the boundary.
  Canonical lifting requires valid UTF-8, so it must be one of them. Shared
  with [DP-0002](0002-strings.md).
- **Allocator algorithm** — free lists, size classes, or bump-with-reset for an
  arena policy; and which raw-memory primitives the compiler exposes to
  `lib/allocator.duni`, and how they are spelled.
- **Memory management** is the larger prerequisite and has its own proposal:
  [DP-0004](0004-memory-management.md), which argues for reference counting on
  the Roc model. It is a pitch, not a settled decision — language pillar 4
  leaves the mechanism open — and nothing in this proposal assumes its
  outcome.

## Alternatives considered

**A bespoke internal layout, adapted at the boundary.** Maximum internal
freedom, and every export pays a marshaling cost. Rejected: matching the
canonical layout makes the boundary free, and Duni has no measured reason to
want a different layout.

**WasmGC instead of linear memory.** Would hand memory management to the
runtime and remove the allocator entirely. Parked as an escape hatch rather
than a direction — components-over-GC is still settling upstream, and the
`(ptr, len)` boundary is what hosts can consume today.

**Deciding layouts per feature, as each type lands.** The status quo. It is how
field order gets decided by whichever `switch` arm was written first, and it is
unfixable once a host depends on it.

## Acknowledgments

The WASM Component Model's Canonical ABI, and Roc's memory-layout work for the
slice and refcount ideas. Prior state of this design lived in
`notes/memory_layout.md`.
