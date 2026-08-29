# 0001: No pointers in the language

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-28

## Context

Duni's compiler is modeled on Zig's, and much of Zig's design is pointer-shaped:
a `type_pointer` in the intern pool, address-of expressions, declarations
represented as a pointer plus a load. Porting a Zig design faithfully therefore
tends to drag pointers in by accident, and with them aliasing, lifetimes, and
the question of what a reference to a dead value means.

## Decision

Duni has no pointer type, no address-of operator, and no reference semantics.
Values are values. When a Zig design is ported, its pointer branches are dropped
rather than translated — declarations are by-value, not pointer-plus-load.

## Consequences

Automatic memory management becomes mandatory rather than optional: with no
pointers there is nothing for a programmer to free, so the runtime owns
lifetimes. In-place mutation is off the table, which is consistent with
immutable values — updates produce new values, and recursion replaces mutable
loop state.

The cost lands on the host boundary: passing bulk data to a WASM host is a
pointer-and-length ABI, so that has to be handled by the compiler and the
`extern fn` calling convention rather than exposed as a language feature.

**Revisit if:** a host interop case cannot be expressed as values plus host
imports. Even then, the first answer is a wider `extern fn` ABI, not a pointer
type in the surface language.
