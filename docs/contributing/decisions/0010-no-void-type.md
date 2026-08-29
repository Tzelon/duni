# 0010: No `void` type yet; `extern fn` return types may lie

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-29

## Context

`extern fn print(x number) number` declares that printing returns a number. It
does not — the host's `print` returns its argument only because something had
to be returned. There is no `void` in Duni: no `Ref`, no `InternPool` entry,
no type.

## Decision

No `void` type. `extern fn print(x number) number` is the honest v1: the
signature is a lie, and the lie is visible and contained.

## Consequences

Every host import must return something, and callers must ignore a value they
did not want. `host.js` returns the argument from `print` for exactly this
reason.

The reason this is not a quick fix: Duni is an expression language where blocks
have values ([0004](./0004-everything-is-an-expression.md)). Adding `void`
means deciding what a void-returning call *yields* as an expression — what
`x = print(1)` binds, what a block ending in a void call evaluates to, and
whether that value can be passed on. That is a language design question, not an
InternPool entry.

**Revisit if:** you want `print`'s type to stop lying — which usually means the
first host import whose real return type is nothing at all, and where returning
a fake value is actively confusing.
