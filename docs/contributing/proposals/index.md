# Proposals

Designs for features that do not exist yet. A proposal is where a language
change is thought through **before** it is built: the syntax, the pipeline
impact, the diagnostics, and the alternatives that lost.

Modeled on [Swift Evolution](https://github.com/swiftlang/swift-evolution),
scaled down to one author. There is no review period, no review manager, and no
vote — the value here is not process, it is being forced to write the design
down while it is still cheap to change.

Copy [`0000-template.md`](./0000-template.md) to the next unused number with a
kebab-case slug.

## When to write one

Write a proposal when a change would alter what a Duni **program** can say:
syntax, semantics, the type system, the standard library's shape, or the host
boundary.

Do **not** write one for compiler-internal work — a refactor, a new IR
representation, an error-reporting improvement. Those are design notes or, if
they settle a durable constraint, [decision records](../decisions/index.md).

The test: would a Duni programmer notice? If yes, proposal. If only a compiler
author would notice, not a proposal.

## Proposals, decisions, and architecture

Three folders, three tenses, and keeping them apart is what stops all three from
rotting:

| | Answers | Tense |
| --- | --- | --- |
| `proposals/` | What should we build, and why this design? | Future |
| `decisions/` | What did we already rule out, and when would that reopen? | Past |
| `architecture/` | How does it work today? | Present |

A proposal that is accepted and implemented does not become documentation —
`architecture/` gets updated instead, and the proposal stays as the record of
how the design was reached. A proposal that is rejected, or that establishes a
constraint on the way to being accepted, leaves a decision record behind.

## Status

Every proposal carries one in its header:

- **pitch** — written, not agreed to. Most proposals stop here for a while.
- **accepted** — the design is settled; implementation has not landed.
- **implemented** — the feature exists and `architecture/` describes it.
- **rejected** — decided against. Leave a decision record, and keep the file.
- **withdrawn** — abandoned before a decision. Also keep the file; the next
  person will have the same idea.

Rejected and withdrawn proposals are not deleted. The reasoning is the asset,
and the same idea arrives again about once a year.

## Open

- [0001 — Diagnostics](./0001-diagnostics.md) (pitch) — one collector across
  Parse/AstGen/Sema, `path:line:col: error: msg`, exit 1
- [0002 — Strings](./0002-strings.md) (pitch) — string parameters, operations,
  encoding guarantees; constants already work
- [0003 — Host boundary ABI](./0003-host-boundary-abi.md) (pitch) — internal vs
  boundary ABI, canonical layout rules, flattening

## Implemented

_None yet._
