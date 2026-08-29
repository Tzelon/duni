# Strings

- **Proposal:** [DP-0002](0002-strings.md)
- **Status:** pitch
- **Date:** 2026-08-29
- **Implementation:** partial — constants work, everything else is unbuilt
- **Decision record:** none

## Introduction

Duni has one string type, `string`: UTF-8 bytes, represented at the boundary as
`(ptr: i32, len: i32)`. String constants already compile and are returned to
the host. This proposal covers what is still undecided — string parameters,
operations, encoding guarantees, and runtime (non-constant) strings.

```duni
extern fn print(s string) number

print("hello")
```

That program panics today.

## Motivation

Strings are further along than they look, and stop dead at the boundary.

**What works, verified:** the scanner lexes string literals, AstGen interns
them, `string_type` exists in the InternPool, and WatGen emits a complete
module for a string-valued program — linear memory, an exported `memory`, a
data segment, and a multi-value `(result i32 i32)` return:

```wat
(module
  (memory 1)
  (export "memory" (memory 0))
  (data (i32.const 0) "hello")
  (func $main (result i32 i32)
    i32.const 0
    i32.const 5
    return)
  (export "main" (func $main)))
```

Constants are assigned offsets in order of first appearance and deduplicated by
handle, so equal strings share one segment.

**What does not work:**

| Program | Result |
| --- | --- |
| `extern fn print(s string) number` | Panic in `AstGen/scratch.zig:73` — a `string` parameter type is unimplemented, with or without a call. |
| `"a" + "b"` | Panic in `Sema/arith.zig` → `Value.toBigInt` — `+` assumes numbers and there is no type check. |
| Any string operation | None exist. No length, no concatenation, no comparison, no slicing. |

The consequence: **a string cannot cross the host boundary.** `host.js` already
carries a commented-out UTF-8 decoder and the comment
`print(ptr: i32, len: i32) — UTF-8 slice out of the module's linear memory`,
waiting for a compiler that can declare such an import.

## Could this be done in Duni?

Partly, and the split is the useful part of this proposal.

**Compiler:** the `string` type itself, the literal, the boundary
representation, and passing a string as a parameter. These are primitives —
there is nothing to build them out of.

**Duni:** every operation. `length`, `concat`, `slice`, comparison, and
formatting are library functions over the primitive, and belong in `lib/`
([0003](../decisions/0003-no-built-ins.md)). The compiler must never learn what
`String.length` is.

The gating question is therefore not "which operations should exist" but "what
primitive do the operations need". Today the answer is: a way to read bytes out
of a `string`, and a way to allocate a new one — which makes runtime strings
dependent on [DP-0003](0003-host-boundary-abi.md) and on memory management.

## Proposed solution

Three pieces, in order of increasing cost:

1. **`string` as a parameter type.** Fixes the panic and lets a string reach a
   host import. Constants only, no allocation — the data segment already holds
   them and the call site pushes the pair.
2. **Type errors instead of panics.** `"a" + "b"` must produce a diagnostic,
   which is [DP-0001](0001-diagnostics.md)'s job; this proposal only fixes the
   message's wording and adds the case.
3. **Runtime strings.** Any string not known at compile time needs allocation
   and a lifetime story. Blocked on memory management; deliberately not
   designed here.

## Detailed design

**Grammar.** No change for 1 and 2. A concatenation operator, if adopted, adds
one infix production.

**Pipeline impact.**

| Stage | Change |
| --- | --- |
| Scanner | None. String literals lex today. |
| Parse / Ast | None for 1–3; one token and one Pratt infix rule if a concatenation operator is added. |
| AstGen | Fix the `scratch.zig` assertion path so a `string` type expression in a parameter position lowers. This is a bug, not a design. |
| Sema | Accept `string` as a parameter type and coerce a string constant to it; reject arithmetic on strings with a diagnostic rather than reaching `toBigInt`. |
| WatGen | Flatten a `string` argument into two `i32` params at the call site — the layout is unchanged from what it already emits for returns. |

**Type rules.** `string` is a distinct type; there is no implicit conversion
between `string` and `number` in either direction. Passing one where the other
is expected is
`expected type 'string', found 'number'` — user-visible names, per DP-0001.

**Zig's answer.** Zig has no `string` type at all: string literals are
`*const [N:0]u8`. Duni cannot copy that, because it has no pointers
([0001](../decisions/0001-no-pointers.md)). The `(ptr, len)` pair exists in the
emitted WAT, not in the language — the same way a stack exists without being a
language feature.

## Open decisions

These are why the proposal exists. Each is cheap now and expensive after
programs depend on it.

- **Is `+` concatenation, or is there a separate operator?** Elixir uses `<>`
  and keeps `+` numeric, which fits "explicit over implicit" and avoids
  overloading a numeric operator with an allocating one. The alternative is
  overloading `+`, which reads better and hides the allocation.
- **Where is UTF-8 validity guaranteed?** At construction, making the boundary
  lowering free, or at the boundary, making construction free. The Canonical
  ABI requires valid UTF-8 when lifting, so one of the two must happen.
  Leaning construction-time.
- **Are strings interned at runtime, or only as constants?** Constants are
  deduplicated by handle today. Extending that to runtime strings is a
  different mechanism with different costs.
- **Comparison semantics.** Byte equality is the obvious answer; anything
  Unicode-aware (normalization, case folding) is a library concern that must
  not leak into the compiler.

## Effect on existing programs

None. No program that compiles today uses a string in any position other than
as the module's result.

## Effect on the host boundary

Piece 1 changes what a host sees: imports may now take two `i32` parameters
where they previously took one `f64`. `host.js` needs its decoder — the one
already written and commented out — enabled.

The representation itself does not change: `(ptr, len)`, `len` in bytes, UTF-8,
no null terminator, no header. That is both what WatGen emits today and the
Canonical ABI's string layout, which is the point — see
[DP-0003](0003-host-boundary-abi.md).

## Testing

- `test/cases/wat/` — one case pinning the data segment, memory export, and
  flattened string argument. The emitted shape is the claim here, so a golden
  is right.
- `test/cases/run/` — `print("hello")` reaching `host.js` and printing it. This
  is the case that proves the boundary works.
- `test/cases/compile_errors/` — `"a" + "b"`, and a string passed where a
  `number` is expected. Both currently panic.

## Future directions

Runtime strings, concatenation, slicing without copying (the "seamless slice"
trick — a tag bit marking a slice that points into someone else's allocation),
and a `lib/string.duni` built on whatever byte-access primitive lands.

## Alternatives considered

**Multiple string types** — `str` / `String` / builder, as Rust and C++ have.
Rejected for the same reason `number` is one type: the split exists to let
programmers manage representation, and Duni does not ask them to.

**Null-terminated strings.** Free interop with C, but a length is O(n), interior
NULs are unrepresentable, and the Canonical ABI wants `(ptr, len)` anyway.

**Deferring the whole topic until memory management lands.** Tempting, since
runtime strings need an allocator. Rejected because pieces 1 and 2 don't: the
constant path is already built, and the only thing standing between it and a
working `print("hello")` is a panic in AstGen.

## Acknowledgments

The one-type philosophy follows `number`. The boundary representation follows
the WASM Component Model's Canonical ABI. Prior state of this design lived in
`notes/string_literals.md`.
