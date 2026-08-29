# 0003: No built-ins — the library is written in Duni

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-28

## Context

The fastest way to make `print`, `if`, or `String.length` work is a special case
in the compiler: match the name in Sema, emit the instruction. Every language
that does this ends up with a standard library that only its own compiler can
implement, and control-flow constructs users can never define themselves.

## Decision

The compiler knows no Duni name. No Duni struct, function, or macro name appears
as a string literal in `src/*.zig`. Control flow, operators, and the standard
library are written in Duni and reach the machine through primitives —
today `extern fn` imports supplied by the host.

## Consequences

The compiler stays a general tool: it handles declarations, calls, types, and
emission, and has no opinion about what a program declares. `print` exists only
because a `.duni` file declared it; delete the declaration and it is gone.

The cost is ordering. Macros, name resolution, and a module story have to land
earlier than they otherwise would, because without them there is nowhere for the
library to live. Some conveniences are unavailable until that work is done.

This is the one pillar that is mechanically checkable: grep `src/*.zig` for Duni
identifiers in string literals. Known exception, recorded rather than fixed —
WatGen hardcodes the import module string `"host"`.

**Revisit if:** a construct genuinely cannot be expressed as a macro over
primitives. Name the construct in the follow-up record; "it would be faster in
Zig" is not the condition.
