# Diagnostics

- **Proposal:** [DP-0001](0001-diagnostics.md)
- **Status:** pitch
- **Date:** 2026-08-29
- **Implementation:** built once on the `fast-forward-to-the-future` branch
  (commit `0814205`), not on `master`
- **Decision record:** none

## Introduction

One diagnostics collector shared by Parse, AstGen, and Sema. Stages record
structured errors with a source location; `main` renders them at the end and
exits 1.

```
$ duni broken.duni
broken.duni:3:1: error: expected 1 argument(s), found 2
```

Today the same program prints `Error: .expected_expression` — or panics.

## Motivation

The case suite encodes the intended behavior and the compiler does not deliver
it. Measured on this branch: **6 of 24 cases pass, 18 fail.** The failures sort
into four kinds, and three of them are this proposal:

| Symptom | Cases | Cause |
| --- | --- | --- |
| exit 64, unstructured stderr | 6 | The error is detected, then thrown away — `main` prints `Error: {tag}` and `process.exit(64)`. No location, wrong exit code. |
| panic (SIGABRT) | 6 | No error path exists. `Sema.coerce` unwraps a null, `analyzeArithmetic` hits `unreachable`, `AstGen.fnDecl` hits `unreachable`. |
| exit 0, nothing reported | 2 | The compiler never noticed — a stray `}` truncates the file, 1000 parens overflow the stack. |
| wrong output, feature bug | 4 | Not diagnostics: `run/runtime_arithmetic`, `run/call_argument_order`, `run/nested_call_argument`, `run/fn_decl_body` are the runtime-values work in progress. |

`bugs/README.md` says the same thing from the other side: twenty reproducible
crashes, every one of them a `.duni` file that made the compiler panic instead
of rejecting the program.

There is also a slow leak. Six sites in `src/` report errors by logging —
`AstGen.zig:301` ("0 cannot be negative"), `Sema.zig:363` and `:562`,
`Parse.zig:495`, `ast.zig:485` — and one of them carries the comment
`log.warn because the test runner fails on log.err`. Error reporting is
currently shaped by what the test runner tolerates.

## Could this be done in Duni?

No, and this is one of the few clear cases. Diagnostics are produced by the
compiler about source it has refused to compile — there is no Duni program
running at that point, and no primitive a macro could reach for. This is
compiler infrastructure, not a language feature
([0003](../decisions/0003-no-built-ins.md) does not apply).

The *wording* of messages is a language design question. Their production is
not.

## Proposed solution

`src/Diagnostics.zig` — one collector, passed to every stage that can reject a
program. An item is `{ loc, msg }`, where `loc` is a union:

- `byte: u32` — for stages that hold the tree and can resolve immediately
  (Parse, AstGen).
- `node_start` / `node_main: Ast.Node.Index` — for Sema, which has no tree by
  design. The renderer resolves the node later.

Rendering happens once, at the end, in `main`: `Diagnostics.render(tree, path,
writer)` maps each location to a byte offset, scans the source for line and
column, and writes `path:line:col: error: msg` to stderr. Exit code becomes
**1** for a rejected program; 64 stays for usage and internal errors, which is
how the harness tells them apart.

Parse keeps its existing recoverable/fatal model and its `Ast.errors` list;
`addParseErrors(tree)` converts those tags to messages in one place, so wording
lives with rendering rather than in the parser.

This design is not speculative — it was built on the
`fast-forward-to-the-future` branch and took the 13 `compile_errors` cases
green. What follows is what that branch learned.

## Detailed design

**Grammar.** No change.

**Pipeline impact.**

| Stage | Change |
| --- | --- |
| Scanner | `Token.Tag.symbol()` — lexeme or a description like `invalid token`, needed by every "found '…'" message. |
| Parse / Ast | `Ast.parse` catches `error.ParseError` instead of leaking it (a fatal parse error is still a parse *result*); `parseRoot` declares `Parse.Error` explicitly. New tag `expression_nested_too_deeply`. Delete the `log.err` in `consume`. |
| AstGen | Gains a `*Diagnostics` param. Every `log.warn` site becomes a structured error. A failed declaration records an empty stand-in so `WipDecls` stays in sync, plus an `any_failed_decls` flag so `generate` fails at the end — a `Dir` with a dropped decl must never reach Sema. |
| Sema | Gains `diags` and `base_node` fields plus `absNode(offset)`; instruction `src_node`s are offsets relative to AstGen's `decl_node_index`, so Sema mirrors that base. Every user-reachable `unreachable` becomes a diagnostic. |
| WatGen | No change. By the time WatGen runs, the program has been accepted. |

**Which token an error points at is per-error-kind, not global.** This is the
part that is easy to get wrong and impossible to guess:

- binary-operator errors → the node's **main token**, the operator itself
  (`1 + "x"` points at `+`);
- call errors (arity, non-function) → the node's **first token**, the callee
  name, not the `(` that is the node's main token;
- argument coercion → the argument's own node, recovered from the arg body's
  terminating `break_inline` `operand_src_node`;
- `expected return type` → the token *before* the cursor, so it lands on `)`
  rather than the following newline.

**Message wording.** Type names in messages are user-visible names, not
internal ones: `f64_type` renders as `number`, via `Type.name()`. Draft each
message with its case file; `compile_errors` compares byte for byte, so the
text is the contract.

**Accumulation.** Parse accumulates (its recoverable model already does).
AstGen and Sema are first-fail-stops: one error per compile, a hard fail aborts
the stage. Multi-error accumulation is deliberately out of scope — see Future
directions.

**Zig's answer.** Zig uses `ErrorBundle` with owned `ErrorMsg`s, notes, source
line snippets, and reference traces. This proposal builds the collector and the
`Loc` union and stops there — the union is the seam the rest attaches to
without reshaping anything.

## Prerequisites

The branch found ten pre-existing bugs that each broke a golden case and had to
be fixed before diagnostics could pass. They are not diagnostics features, and
they will surface again in the same order:

1. `Ast.parse` leaks `error.ParseError`, so callers never see `tree.errors`.
2. A stray `}` at top level is silently ignored — `parseBlock` serves both root
   and brace blocks and treats `}` as a terminator, dropping the rest of the
   file with exit 0.
3. `findNextStmt` stops at any `}`, so recovery inside a broken `fn` body emits
   a second bogus error. Needs brace-depth tracking.
4. `fn` and `extern` parse anywhere, being Pratt prefix rules, so
   `1 + fn f() number {}` builds an AST and crashes AstGen.
5. No expression depth limit — 1000 parens overflow the native stack.
6. An invalid token in infix position blames the newline.
7. `consume()` logs on the error path.
8. User-reachable `unreachable`s in Sema: `coerce` on a string, non-function
   callee, non-numeric arithmetic operands.
9. A module with no value-producing statements has nothing to return.
10. AstGen declaration failures are swallowed and desync `WipDecls`.

## Effect on existing programs

The exit code for a rejected program changes from 64 to 1. Nothing else
observable changes, because nothing that compiles today produces a diagnostic.

## Effect on the host boundary

None.

## Testing

`test/cases/compile_errors/` is the acceptance test — 13 cases, byte-exact
stderr, exit 1. They are already written and currently failing, so the proposal
has its oracle before the first line of code.

The implementation order that worked, each step compiling and testable alone:

1. `src/Diagnostics.zig` plus its unit test, standalone.
2. `Token.Tag.symbol()`.
3. Parser fixes: prerequisites 1–7.
4. `addParseErrors` plus `main` render and exit-code plumbing. **Parse-level
   cases go green here.**
5. AstGen: the `*Diagnostics` param, log-site conversion, failed-decl stand-in.
6. `Type.name()`, then Sema: fields, `absNode`, and every site converted.
7. Run the full `compile_errors` suite.

Two mechanical costs to plan for: `AstGen.generate` and `Sema.analyze` grow a
parameter, so roughly fifteen call sites and tests need a local collector — do
the signature change in one commit, since half-wired states do not compile. And
the CLI prints the path as given while the harness strips its own copy, so
normalize a leading `./` before rendering or the strip leaves `./:1:1:` behind.

## Future directions

Deliberately not built: multi-error accumulation in AstGen and Sema, notes
attached to errors, source-line-and-caret rendering, color, and a full
`ErrorBundle`. Each attaches to the `Loc` union without reshaping it.

## Alternatives considered

**Keep per-stage error lists.** Today Parse owns `Ast.errors` and other stages
own nothing. Extending that pattern means three list types, three renderers,
and three chances for a stage to print instead of collect — which is how the
six logging sites happened.

**Print immediately at the failure site.** Simplest, and it is what the logging
sites do now. It makes byte-exact testing impossible to keep honest, orders
messages by internal control flow rather than source position, and puts the
message in the deepest, least contextual place in the compiler.

**Build `ErrorBundle` now.** Zig's shape is the eventual destination, but its
value is in notes, snippets, and cross-references — none of which exist yet.
The `Loc` union is the smallest thing that does not have to be undone.

## Acknowledgments

Zig's `ErrorBundle` and `Module.ErrorMsg` are the reference. The design and the
prerequisite list come from the `fast-forward-to-the-future` branch, where this
was built end to end before being written down.
