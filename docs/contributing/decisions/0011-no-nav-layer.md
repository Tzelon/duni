# 0011: No `Nav` layer — a `decls` map is the declaration layer

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-29

## Context

Zig's `InternPool` has a `Nav` — a "named addressable value", the slot a source
declaration resolves to. Since Duni's compiler mirrors Zig's
([compiler pillar 1](../project-intent.md)), the default assumption is that
Duni needs one too.

## Decision

No `Nav`. Sema resolves declarations eagerly and whole-program into a `decls`
map (`Dir.NullTerminatedString` → `Air.Inst.Ref`), and `.decl_val` is a lookup
in that map. The map lives on `Sema`, not on a `Namespace`.

## Consequences

A `Nav` carries machinery Duni has no use for: two-state lazy resolution for
incremental rebuilds (`analysis` versus `resolved`), a namespace plus a
fully-qualified name, per-declaration backend attributes (align, linksection,
addrspace, threadlocal, const), and generic instantiation via `generic_owner`.
Zig splits the declaration from the value it resolves to because a `Nav` may be
a var, a function, or a generic instance.

Duni collapses that. An extern *value* (`Key.Extern{ty, name, lib_name}`) is
self-contained — WatGen emits `(import "host" "print" …)` from it alone — and
the eager `decls` map is the declaration layer. A declaration's name lives both
in the map key and in the value; that duplication is intentional, and Zig does
the same, because the value must stand alone for codegen.

Because AstGen deduplicates identifiers, a declaration's name and a
`decl_val`'s name are the same `Dir` string handle, so the lookup is handle
equality with no re-interning.

Adopting a `Nav` would import Zig's premise — lazy, incremental,
multi-namespace, backend-attributed — without Duni having any of those
requirements.

**Revisit if:** any one of incremental compilation, real namespaces or modules,
per-declaration backend attributes, or generics lands. Each is deferred
elsewhere; whichever arrives first needs a declaration slot richer than a
name-to-index map, and that is when a `Nav`-like layer earns its place.
