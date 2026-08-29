# Memory management

- **Proposal:** [DP-0004](0004-memory-management.md)
- **Status:** pitch
- **Date:** 2026-08-29
- **Implementation:** none
- **Decision record:** none — [pillar 4](../project-intent.md) says "automatic
  memory management" and deliberately leaves the mechanism open. This proposal
  is the argument for closing it.

## Introduction

Duni manages heap values with **reference counting**, not a tracing collector.
The compiler inserts allocation, `inc`, and `dec` calls when lowering
heap-producing operations; the allocator itself is written in Duni.

Nothing here exists yet. The proposal is a direction, so that allocation work
builds toward one answer instead of accumulating decisions by accident.

## Motivation

Duni allocates nothing today. `WatGen` emits a fixed `(memory 1)` — one 64 KiB
page — and every string constant lives in a data segment at a compile-time
offset. There is no `memory.grow`, no allocator, no free.

That ceiling is reached by the next three features. Runtime strings
([DP-0002](0002-strings.md)), lists, and records all produce values whose size
is unknown at compile time, and each one needs the same two answers: where does
the memory come from, and who releases it. Answering that per-feature is how a
language ends up with three allocation strategies and no story.

The pillar list already commits to the user-facing half — you never free
anything and never see a pointer ([0001](../decisions/0001-no-pointers.md)).
What is open is how.

## Could this be done in Duni?

Split, and unusually cleanly:

- **Duni:** the allocator. It lives inside the module as `lib/allocator.duni`,
  built on the only genuine primitives — raw load/store and `memory.grow` —
  the same shape as Zig's std allocators. Policy is swappable at the Duni level
  (general-purpose versus arena), selected per module.
- **Compiler:** deciding *where* `inc`, `dec`, and allocation calls go. That is
  a lowering decision made from type and lifetime information the program does
  not have access to.

The allocator being Duni code is what makes the ambient design honest: the
compiler calls a function, it does not implement one
([0003](../decisions/0003-no-built-ins.md)).

## Proposed solution

**Reference counting, on the Roc model.** Three reasons, in order of weight:

**Immutability makes plain RC sound.** Duni data is immutable, so a value can
only reference values that already existed when it was created. The reference
graph is a DAG; cycles are impossible; no cycle collector is needed. This is
the load-bearing argument, and it is a **language invariant, not a happy
accident** — if Duni ever gains mutable references to heap values, cycles
become constructible and plain RC leaks. Any such feature must revisit this
proposal first.

**WASM economics.** A tracing collector ships inside every module and needs
root finding, which core wasm makes hard — no stack introspection, so you need
shadow stacks or root spilling. RC is inc, dec, and free: a tiny runtime. Wasm
is single-threaded today, so the counts are non-atomic and cheap.

**Deterministic frees.** Memory returns at the last decrement. No pauses, no
tuning, predictable footprint. The one trade is real: dropping a large
structure frees recursively at that moment, a latency spike a collector would
amortize.

## Detailed design

**The refcount header lives before the pointer.** Roc stores it at `ptr - 8`;
the pointer itself points at the data. This keeps every layout in
[DP-0003](0003-host-boundary-abi.md) untouched — `string` stays `(ptr, len)`,
and boundary lowering stays near-free. The header is an allocation detail,
never a type-layout detail, and a host reading `(ptr, len)` never sees it.

**Constants are immortal.** Values in `(data ...)` segments cannot be freed. A
reserved refcount value marks them, so decrements on constants are no-ops. This
matters immediately: every string in Duni today is such a constant.

**Naive first, Perceus later.** Day one is plain inc/dec everywhere — correct
and chatty. The known improvement is Perceus-style static reference counting
(Koka, Lean, and what Roc does): elide operations for borrowed values, and
reuse or mutate in place when the count is provably 1, which is how a
functional API gets imperative performance. That is a Sema-level analysis to
grow into, not a runtime change, so the naive version is not throwaway work.

**Ambient allocator.** One current allocator per module. User code never
mentions memory — no Zig-style allocator threading through signatures. The only
parties aware of it are the standard library author and the compiler.

**Pipeline impact.**

| Stage | Change |
| --- | --- |
| Scanner, Parse | None. |
| AstGen | None initially — allocation is a lowering concern, not a syntax one. |
| Sema | Knows which operations produce heap values, and eventually hosts the Perceus analysis. |
| WatGen | Emits calls to `alloc`, `inc`, `dec`; grows memory via the allocator rather than a fixed `(memory 1)`; exports the allocator entry points. |

**Primitives the compiler must expose to `lib/allocator.duni`:** raw load and
store at an address, and `memory.grow`. How they are spelled is open — they are
the only place Duni code touches memory as memory, and they must not become
generally callable.

## Effect on existing programs

None today. Every current program is constants and folded arithmetic.

## Effect on the host boundary

The module's exported surface grows: `alloc` and `free` for the tight door, and
later a `cabi_realloc` thunk that is a thin wrapper over the same allocator for
the component door. Arena reset and similar policy controls are plain exports
rather than host-provided functions.

At the component edge, a lift copies a value out into the receiver's memory;
`post-return` is where the source's decrement belongs.

## Testing

Reference counting is the hardest thing yet to test, because correctness is
invisible in program output — a leak and a correct free print the same thing.

`run/` cases prove nothing on their own. The suite needs an observable: an
exported allocation counter or current-heap-size that a case can assert
returned to its starting value, checked from `host.js`. That observable should
be designed with the feature rather than bolted on, and a double-free must be a
loud trap, not silent corruption.

## Future directions

- **Perceus static RC** — elision and in-place reuse.
- **Seamless slices** — a tag bit in the capacity field marking "points into
  someone else's allocation, don't free through me", enabling copy-free
  substrings. It interacts with RC directly: a slice must keep its backing
  allocation alive, so the bit redirects inc/dec to the original allocation's
  header.

## Alternatives considered

**Tracing GC.** Amortizes the recursive-free spike and tolerates cycles. It
ships a collector inside every module and needs root finding that core wasm
does not provide. Rejected on WASM economics, not on principle.

**WasmGC.** Hands memory management to the runtime and removes the allocator
entirely. Parked as the escape hatch if RC's invariants ever break — for
instance if mutable heap references arrive — rather than as a direction:
components-over-GC is still settling upstream, and the `(ptr, len)` linear
memory boundary is what hosts consume today.

**Arena only, never free.** Genuinely viable for short-lived embedded programs,
and it is roughly what the fixed `(memory 1)` does now. Rejected as the default
because `slime.duni` is a long-running loop, which is exactly the shape that
cannot leak per frame. Arena stays available as a swappable policy.

**Ownership and borrow checking.** No runtime cost at all. Rejected as
incompatible with the language's stance: it is precisely the memory reasoning
pillar 4 promises users they will never do.

## Acknowledgments

Roc's memory model — refcount placement, immortal constants, seamless slices —
and Koka and Lean for Perceus. Prior state of this design lived in
`notes/memory_layout.md`.
