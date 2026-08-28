# Duni — Tail Calls (`return_call`)

Executes the decision in `notes/type_system.md` §2: Duni has no loops —
iteration is tail recursion, and WASM has no implicit TCO, so the compiler
**requires the wasm `tail_call` feature** and emits `return_call`. Full TCO
including mutual recursion, no compiler transformation (no loop-ification).

## The guarantee

**Every call in tail position is emitted as `return_call`.** Uniform — a
call to a defined function and a call to a host extern alike. A guaranteed-
TCO language cannot special-case: a deep mutual loop through any helper
must run in constant stack, and "tail call unless X" is surface that has to
be specified and remembered.

## What is a tail position

A purely structural property of the Air, derived per function:

- The final `ret`'s operand is in tail position.
- If a tail-position ref is a `block`, then the operand of every `br`
  targeting that block is in tail position (the merge value flows only to
  the `ret`) — recursively, so `if`/`else` chains propagate it into every
  branch.
- A tail-position ref that is a `call` is a tail call.

Nothing else is: a call whose result feeds an operation (`1 + f(x)`), a
call argument, a non-final statement.

## Where it is detected — WatGen only

Per the effort table in `notes/type_system.md` §8, detection lives in
`WatGen` (a pre-pass over the function's Air, before locals are assigned).
Sema and the Air encoding are untouched: tail position is derivable from
structure, and codegen is the only consumer today. Revisit only if a future
pass needs the marking earlier.

## Emission

A tail call replaces the whole "store, merge, return" tail of the normal
path:

- the call site emits `return_call $callee` after pushing its arguments —
  no result local is allocated and no `local.set` follows (the call never
  returns here);
- a `br` whose operand is a tail call emits nothing (control already left
  the function);
- a `ret` whose operand is a tail call emits nothing.

A block stays declared even when every one of its brs turned into tail
calls: its merge local is then unused and the trailing `local.get`/`return`
is unreachable — both valid wasm, kept for emitter simplicity.

Type discipline is inherited: wasm requires the callee's result type to
match the caller's; Sema's return coercion already guarantees it.

## Toolchain requirement

Set the moment the first `return_call` is emitted (this arc):

- `wat2wasm --enable-tail-call` in the case harness;
- Node with wasm tail calls (on by default since V8 11.2 / Node 20).

Standardized feature; shipped in V8, SpiderMonkey, and wasmtime since
~2023. This is a *minimum engine requirement* of the language, not a build
option.
