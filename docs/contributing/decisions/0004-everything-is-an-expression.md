# 0004: No statement/expression split

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-28

## Context

Most C-family languages separate statements from expressions, and the grammar in
`grammar.y` still carries that shape in places. The split forces a second
parsing layer, and it makes constructs like `if` un-expressible as library code,
because a statement cannot produce a value to hand back.

## Decision

Everything in Duni is an expression. Blocks evaluate to their last expression,
`=` is a binding that is itself an expression, and there is no statement layer in
the parser or the IR.

## Consequences

Parsing is Pratt-first with no separate statement grammar. `if` can be a macro
that produces a value, which is what makes [0003](./0003-no-built-ins.md)
achievable rather than aspirational.

The cost is that every construct must have a value, including ones that
naturally have none. That forces a decision about the unit/void type earlier
than a statement-based language would need it — an `extern fn print(x number)
number` that returns a meaningless number is the current stand-in.

**Revisit if:** never expected. A construct that cannot produce a value is a
signal that the unit type needs work, not that statements should return.
