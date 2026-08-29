# Feature name

- **Proposal:** [DP-NNNN](NNNN-feature-name.md)
- **Status:** pitch <!-- pitch | accepted | implemented | rejected | withdrawn -->
- **Date:** YYYY-MM-DD
- **Implementation:** none yet <!-- branch, commit, or PR -->
- **Decision record:** none <!-- link if this produced or was settled by an ADR -->

## Introduction

One paragraph. What is being proposed, and what does a program using it look
like? Show the syntax immediately — a reader should know what they are looking
at before the motivation.

```duni
# The feature, in the smallest program that demonstrates it.
```

## Motivation

What can't be expressed today, or what is expressed badly? Show the current
workaround and why it is unsatisfying. If the answer is "nothing, but it would
be nicer", say so — that is a legitimate motivation, and being honest about it
changes how much complexity the feature is allowed to cost.

Link the cases in `test/cases/` that fail or can't be written today.

## Could this be done in Duni?

**Answer this before designing anything.** Duni's core is small on purpose
([0003](../decisions/0003-no-built-ins.md)): control flow, operators, and the
standard library belong in `lib/*.duni`, not in `src/*.zig`.

- If the feature can be a macro or a function over existing primitives, then the
  proposal is a library proposal and the compiler sections below are empty.
- If it cannot, name the primitive that is missing and why no combination of
  existing ones reaches it. "It would be faster to special-case in the compiler"
  is not an answer.

## Proposed solution

The design in prose, aimed at someone who will use the feature rather than
implement it. Cover the ordinary cases first, then the edges. Say what the
feature does *not* do.

## Detailed design

Enough that someone else could build it.

**Grammar.** The productions added or changed, in `grammar.y`'s notation.

**Pipeline impact.** Every stage the feature touches, in order. State "no
change" explicitly where a stage is untouched — a proposal that silently skips a
stage usually forgot it.

| Stage | Change |
| --- | --- |
| Scanner (`src/scanner.zig`) | new tokens, or none |
| Parse (`src/Parse.zig`, `src/Ast.zig`) | new node tags, `Data` shapes, `extra_data` payloads |
| AstGen (`src/AstGen.zig`) | lowering to DIR, scope handling, new DIR instructions |
| Sema (`src/Sema.zig`) | typing rules, folding, new AIR instructions |
| WatGen (`src/WatGen.zig`) | emitted WAT |

**Types.** How the feature types, including what is rejected and the diagnostic
each rejection produces. Error messages are the interface — draft their exact
text here, not after implementation.

**Zig's answer.** Duni's compiler mirrors Zig's
([compiler pillar 1](../project-intent.md)). Say how Zig handles the equivalent
feature and where this proposal deviates. Deviating is fine; deviating without
noticing is not.

## Effect on existing programs

Does any program that compiles today change meaning or stop compiling? For a
language with no users this is cheap to answer — say so plainly rather than
leaving the section out, because it stops being cheap later.

## Effect on the host boundary

Does this change what a host must provide, or what a compiled module exports or
imports? Most features do not. If it does, the host contract is part of the
design, not an implementation detail.

## Testing

Which case flavors prove this works, per
[testing principles](../testing-principles.md):

- `test/cases/run/` — the behavior, observed by running it.
- `test/cases/compile_errors/` — every diagnostic drafted above.
- `test/cases/wat/` — only if the emitted shape is itself the claim.

Name the cases you expect to add. If a case is hard to write, that is a finding
about the design, not about the harness.

## Future directions

What this deliberately leaves for later, and what it makes possible. Keep the
speculation short and clearly separated from the proposal — nothing here is
being agreed to.

## Alternatives considered

Every design seriously entertained and why it lost. A proposal with no
alternatives section either had none, which is rare, or discarded them without
recording why, which is the expensive kind of forgetting.

## Acknowledgments

Prior art worth naming — the language this was borrowed from, the note or
conversation that started it.

---

**Proposals vs decision records.** A proposal is forward-looking: it designs
something before it exists. A [decision record](../decisions/index.md) is
backward-looking: it captures a choice already made, usually a no. A proposal
that gets rejected, or that settles a durable constraint on its way to being
accepted, should leave a decision record behind — the proposal explains the
design, the record is what the next person is required to read.
