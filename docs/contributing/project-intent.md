# Project intent

`Duni` is a statically-typed, expression-oriented programming language.
Its compiler is written in Zig and emits WebAssembly text (WAT).

## Language core pillars

1. Immutable values, rebindable names.
2. Everything is an expression.
3. Statically typed.
4. Automatic memory management.
5. Explicit over implicit.
6. Small core, extended in Duni.
7. Recursion is the loop.
8. Pragmatic functional, not pure.

## Compiler core pillars

1. Zig's compiler is the reference, deviations get written down as (ADR).
2. Data-oriented: flat arrays and indices, never node pointers.
3. One direction, one job per stage.
4. WAT is the only backend.
5. Actionable errors, never panics.
6. No built-ins.

## What this repo is

This repository is:

- Duni compiler: scanner, parser, AstGen, Sema, WAT emission.
- A place to learn compiler construction by building one the long way.

When docs or code reflect starter-oriented conventions and conflict with the
guidance here, treat this document as the project's intent.

## Who this is for

Duni is a language for programs that run on a WASM host. The program provides logic,
the host provides capabilities.

Optimize for:

- Embeddable in any WASM host.
- Fast iteration with AI agents.
- Delight of coding.

It does not need to optimize for:

- Systems programming.
- Performance at any cost.

## What not to assume

When working in this repo, do not assume:

- grammar.y and slime.duni describe what exists. They describe the destination.
- A missing feature is an oversight. Many are deliberate deferrals with recorded triggers.
- A new feature belongs in the compiler. The default is the opposite: if it can be done in Duni, it is done in Duni.
- Zig's answer is automatically Duni's. Zig is the reference for shape, data-oriented IRs, Sema, InternPool.
  It is not the reference for semantics, Duni has no pointers and no manual memory, so any design that leans on them is the wrong port.

Also do not document capabilities as if they already exist. Keep design notes
and proposals clearly labeled, and keep present-tense claims limited to behavior
that exists in the repository.

## Documentation guidance

When updating docs or explaining architecture:

- Prefer focused docs over expanding `AGENTS.md`.
- Prefer a checker over a should-list. A rule that can be grepped or tested belongs in the build, not in prose.

## Agent guidance

If you are an agent working in this repo:

- Guide, don't implement. Unless asked for code, the deliverable is an explanation or a plan, not a diff.
- Read this file before making product-level decisions.
- Answer the question that was asked. A diagnostic question ("why does this crash?") wants an explanation, not a proactive fix.
- Build the permanent version now. If a design works only because a feature is missing and has to be redone when it lands,
  that's a shortcut with a delayed bill.
- Don't argue for the minimal version. Scope and depth are the author's call.
  Propose the design that makes the next arc easier, let the author decide to cut it.
