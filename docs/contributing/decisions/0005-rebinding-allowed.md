# 0005: Rebinding is allowed; there is no redeclaration error

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-28

## Context

With immutable values, a program still needs to compute intermediate results
under a convenient name. Two options: forbid reuse of a name in a scope (Zig's
redeclaration error), or allow a name to be bound again, shadowing the previous
binding (Elixir).

## Decision

Rebinding is allowed. `x = 1` followed by `x = 2` pushes a new binding that
shadows the old one. There is no redeclaration check, and the only
name-resolution error is "use of undeclared identifier".

## Consequences

Values stay immutable — nothing is mutated, a new binding simply wins from that
point on. Any value captured before the rebind still refers to the old one.

The cost is that the code reads like assignment while behaving like shadowing,
which is the usual source of confusion in Elixir. It also means a typo in a name
on the left of `=` is silently a new binding rather than an error, so the
mistake surfaces later, at the use site.

**Revisit if:** shadowing across nested scopes or closures proves to be a
frequent source of real bugs. The fix would be a warning, not a redeclaration
error.
