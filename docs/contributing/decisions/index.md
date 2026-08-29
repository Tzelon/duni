# Decision records

A **steering veto list**. Open the list below before proposing a new node tag,
IR instruction, syntax form, or compiler stage. Architecture docs and code
describe how the system works today; this folder records decisions **already
made**, usually a no with a revisit-if.

Linked from [AGENTS.md](../../../AGENTS.md) for that check — not as homework and
not as a museum.

A good record is half a page: context, the decision, consequences. See
[0000](/docs/contributing/decisions/0000-template.md) for the shape.

Decision records are point-in-time documents, everything else in `docs/` describes current
behavior (see [documentation principles](../documentation.md)).

## When to add a record

Write one after you have already decided **not** to build something the next
agent will otherwise re-propose. Copy [`0000-template.md`](./0000-template.md)
to the next unused number (read this index on `master` first) with a kebab-case
slug. Keep it to roughly half a page.

Do **not** write an ADR on every PR.

When a later record changes a decision, mark the old one `superseded by NNNN`
rather than editing or deleting it, and list it under
[Historical / implementation](#historical--implementation).

Add new steering records to the steering list, not a catch-all numbered dump.

## Steering list

Open these before proposing a new node tag, IR instruction, syntax form, or
compiler stage.

- [0001 — No pointers in the language](./0001-no-pointers.md)
- [0002 — WAT is the only backend](./0002-wat-only-backend.md)
- [0003 — No built-ins; the library is written in Duni](./0003-no-built-ins.md)
- [0004 — No statement/expression split](./0004-everything-is-an-expression.md)
- [0005 — Rebinding is allowed; there is no redeclaration error](./0005-rebinding-allowed.md)

## Historical / implementation

Accepted or superseded records that do **not** change the next proposal. Do not
treat this list as homework. History stays; it is not silently deleted.

- [0006 — Zig-style closed node tags, not open forms](./historical/0006-closed-node-tags-over-open-forms.md)
  — the form-based AST was implemented and reversed; the macro system pays the
  bill at a later lowering stage
