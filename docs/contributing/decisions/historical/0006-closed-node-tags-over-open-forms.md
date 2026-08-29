# 0006: Zig-style closed node tags, not open forms

- **Status:** draft — record of a decision made and reversed <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-07-31 (reversal), recorded 2026-08-28

## Context

Duni wants Elixir-style macros, and Elixir's AST is uniformly `{name, meta,
args}` where `name` is an interned atom from an open universe — anyone can mint
`:unless` or `:my_macro` without a compiler change. The original AST design
followed that: a small closed set of node *kinds* (`int_lit`, `str_lit`,
`symbol`, `form`) with operators living as interned symbols inside `.form` data
rather than as Zig enum variants. Operators, `if`, and user macros would all be
the same shape, and a quoted form could be read straight off the AST.

That design was implemented — functions, calls, and binds all lowered as forms.

## Decision

Reversed on 2026-07-31 in favor of Zig-style closed per-construct `Node.Tag`s
with compact `Data` payloads, mirroring `lib/std/zig/Ast.zig`. Today's tags are
`root`, `number_literal`, `string_literal`, `identifier`, `negation`, `add`,
`sub`, `mul`, `div`, `assign`, `block`, `call`, `fn_decl`, `fn_proto`,
`grouped_expression`. The `form` node is gone.

## Consequences

The parser no longer needs the InternPool — `Ast.parse(gpa, source)` takes no
pool, and names (fn name, param names, callee) are recovered from tokens the way
Zig does it. Every consumer can `switch` exhaustively over a closed enum, which
is what makes missing cases a compile error rather than a runtime surprise.

The cost is paid by the future macro system: a quoted representation has to be
built at a later lowering stage instead of being the AST's native shape. That is
the bill this record exists to make visible — see
[0003](../0003-no-built-ins.md), which depends on macros arriving.

The full argument for the form-based design — why operators were not going to be
Zig enum variants, and the memory trade-offs behind that — lived in
`notes/ast_structure.md`, deleted once this record existed. Recover it from git
history if the reasoning is ever needed again. A condensed version survives in
[architecture/functions.md](../../architecture/functions.md) under
"Historical — the form-based AST design".

**Revisit if:** building the quoted representation at a later stage turns out to
need information the closed-tag AST has already discarded.
