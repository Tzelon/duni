# 0009: A module is a script, not a program with `fn main`

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-29

## Context

A Duni file today is a script: its top level is a body of statements, and the
value of the last one is what `main` returns. The alternative — requiring a
`fn main` declaration and making the top level a list of declarations — is what
most compiled languages do, and Zig's `setStruct` container encoding assumes it.

WASM is neutral on this. It only needs an exported function; the start section
is `[] -> []` and init-only, and `_start` is a WASI convention rather than a
requirement.

## Decision

The module payload is a body to execute, not a decl list to resolve. Script
mode stays.

This is a deferral with a recorded trigger, not a permanent position. The whole
extern-function staging depends on the implicit main body being analyzable by
today's Sema, and changing it now would invalidate that work for no gain.

## Consequences

`Dir`'s module encoding stays simple: `module_decl` is an `.extended`
instruction at index 0 whose payload is `ModuleDecl{src_node, body_len}` plus
an ordered body. There is no decl list, no `decls_len`, and no conditional
header fields.

The cost is a question with no good answer under script mode: **can a function
body reference a top-level binding?** `x = 1` followed by
`fn f() number { x }` forces a design for globals or capture, and the honest
answer is that script mode was never meant to carry it.

Do **not** build top-level-bindings-as-wasm-globals. That is the expensive
fork, and it buys a feature this decision is deferring rather than solving.

**Revisit if:** anyone asks whether a function body can see a top-level
binding. That question is the trigger — the answer is to switch to `fn main`,
not to extend script mode. It lands naturally with the namespaces arc.

Note that [DP-0003](../proposals/0003-host-boundary-abi.md) pushes in the
other direction: an embedded module exports `init`/`tick`/`render` for a host
to call, and a host does not run your `main`. Whichever way this is resolved,
the two records must agree.
