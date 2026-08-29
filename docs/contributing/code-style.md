# Code style

Adapted from [TigerStyle](https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md).
The framing is theirs; the rules here are Duni's, and where TigerBeetle's goals
differ from a compiler's, the rules differ too.

## Why have style

Style is design. Our design goals, in this order:

1. **Correctness.** A compiler that is wrong is worse than one that is missing
   features, because everything downstream inherits the mistake silently.
2. **Understandability.** The point of this repository is that one person can
   hold the whole compiler in their head. A clever line that costs an hour to
   re-read has a negative return.
3. **Performance.** Last, and mostly not yet. See
   [0002](./decisions/0002-wat-only-backend.md) — the data-oriented shapes here
   are copied from Zig for their design, not because anything was benchmarked.

Every rule below serves one of those three. Where a rule doesn't, delete it.

## Zig — the compiler

### Formatting

- Run `zig fmt src/` before committing. It settles indentation (4 spaces),
  braces, and wrapping. Don't argue with it.
- Aim for 100 columns. Ninety-six lines currently exceed it; that's a debt, not
  a license. To wrap a signature or call, add a trailing comma and let `zig fmt`
  do the rest.

### Naming

- `snake_case` for functions, variables, and fields. `CamelCase` for types.
- **File names follow Zig's convention:** a file that *is* a struct is
  `CamelCase.zig` (`Ast.zig`, `Parse.zig`, `Sema.zig`, `WatGen.zig`,
  `InternPool.zig`). A file that is a namespace of functions is lowercase
  (`scanner.zig`, `string.zig`, `main.zig`).
- **Never abbreviate.** Not in variables, not in parameters, not in helpers.
  `parseExpression`, not `parseExpr`; `current_scope`, not `cur`. The exception
  is an established domain word already used throughout (`gpa`, `ast`, `ip`).
- Infuse names with meaning. `gpa: Allocator` and `arena: Allocator` say more
  than `allocator: Allocator` — they tell the reader whether `deinit` is coming.
- Put units and qualifiers last, most significant first: `params_start`,
  `params_end`, not `start_params`. Related names then line up in source.
- When a helper exists only for one caller, prefix it with the caller's name so
  the call history is visible in the identifier.

### Types and indices

- **Index kinds are distinct types, never bare integers.** `Node.Index`,
  `Node.OptionalIndex`, `Node.Offset`, `ExtraIndex`, `InternPool.Index` are
  separate enums precisely so the compiler rejects mixing them. A `u32`
  parameter that is really a node index is a bug waiting for a refactor.
- Use explicitly-sized types (`u32`, `i64`). Avoid `usize` except where an API
  demands it.
- Prefer the smallest signature that carries the meaning. As a return type,
  `void` beats `bool`, `bool` beats `?T`, `?T` beats `!T`. Every extra
  dimension is a branch at every call site, and it propagates.

### Data layout

- Variable-length data goes in the flat `extra_data: []u32` array, referenced by
  a `SubRange` or `ExtraIndex`. It does not go inline in a node, and it does not
  become a heap-allocated list hanging off a node.
- Nodes live in a `MultiArrayList`. Keep `Data` payloads within their size
  budget — `Air.Inst.Data` is exactly 8 bytes, and a `union(enum)` that pushes
  past it is a design error, not a tuning problem.
- Store tokens you will need later rather than deriving them. `rparen` and
  `rbrace` live in the extra structs so `lastToken` returns a stored answer,
  never a scan — derivation breaks under error recovery, where the tokens a
  scan would need may have been skipped.

### Memory

- Allocators are passed explicitly, never stored globally. The parameter is
  named for its kind (`gpa`, `arena`), because the name is the ownership
  contract.
- Say who owns what and who frees it. `Ast.parse` returns an `Ast` that owns its
  `tokens`, `nodes`, `extra_data`, and `errors`; the caller calls
  `tree.deinit(gpa)`. Anything that allocates documents this in the same breath.
- Phase-scoped scratch memory is reused, not reallocated per item — see
  `Parse.scratch`, which collects list elements before they are flushed into
  `extra_data`.

### Control flow

- **Push `if`s up and `for`s down.** Keep branching in the parent function and
  move straight-line work into helpers. One function should own the control
  flow; the rest shouldn't know there was a decision.
- Keep functions short enough to read without scrolling. When one grows past
  that, the split that feels right is almost always "extract the non-branching
  middle", not "cut it in half".
- **Recursion is allowed where the grammar is recursive** — a recursive-descent
  parser and an AST walk are the honest shape of the problem. It must be
  bounded: nesting depth is checked and reported as a real diagnostic
  (`test/cases/compile_errors/expression_too_deep.duni`), never left to blow the
  stack.
- Split compound conditions into nested `if`/`else` so every case is visible.
  State invariants positively: `if (index < count)`, not `if (index >= count)`.

### Assertions and unhandled cases

- Assert what a stage guarantees to the next one. Assertions are documentation
  the compiler checks, and they turn "wrong output much later" into "crash
  here".
- Split them: `assert(a); assert(b);` beats `assert(a and b);` — the failure
  tells you which half broke.
- **Handle only the cases that exist today.** An `AstGen` switch covers the node
  tags `Parse` actually emits and panics on the rest. A speculative arm for a
  tag nothing produces is untested code that will be wrong when the tag finally
  arrives, and it hides the gap in the meantime.

### Errors

- Distinguish **recoverable** from **fatal**. Recoverable errors append to
  `errors` and parsing continues (`warn*`); fatal errors append and unwind
  (`failMsg` → `error.ParseError`). Choosing correctly is what keeps one typo
  from producing twenty diagnostics.
- Recover at the smallest scope that resyncs — `findNextStmt` and friends,
  tracking brace depth so recovery stops at the right level. Resyncing too far
  up cascades one mistake into many.
- **Never print on an error path.** No `log.*`, no `std.debug.print`. Errors are
  collected (`Ast.errors`) and rendered by the caller; stray output breaks the
  byte-exact `compile_errors` cases, which is the check that keeps error
  messages from rotting.
- Errors are the interface, not a debug aid. An agent or a user iterates by
  reading them.

### Organization

- **AST consumers are standalone visitor modules**, not methods hanging off
  `Ast`. `Ast` owns the data; walking it is somebody else's job.
- An `@import` used by exactly one function goes inside that function, not in
  the top-of-file block. The import list should describe what the file depends
  on broadly, not every leaf helper.
- Order a file top-down: fields, then types, then functions, with the important
  ones first.

### Comments

- Say **why**. The code already says what. A comment that restates the line
  below it is noise; a comment explaining why the obvious approach was rejected
  is the most valuable line in the file.
- Comments are sentences: capital letter, full stop. End-of-line comments can be
  phrases.
- Never delete an existing comment unless you delete the code it describes, and
  update it when you change that code.

## Duni — `lib/*.duni` and examples

- **Every public declaration has an `@doc`.** Every `struct`, `fn`, and `macro`.
  No exceptions.
- `@doc` always uses a heredoc `"""`, even for one line, and goes immediately
  before the declaration it documents — a struct's doc sits outside the struct,
  not inside the body.
- **A blank line after every closing `"""`**, before the next declaration or
  attribute.
- Descriptive names, same rule as the Zig side. No cryptic parameters.

## Tests

- A regression test is a file. Add a `.duni` file under `test/cases/` with a
  footer declaring the expected result — no Zig code. See
  `test/cases/README.md`.
- Unit tests are per stage: hand the stage its input directly and assert its
  output. Don't chain upstream stages to produce the input, or a parser change
  breaks a `Sema` test.
- One case per distinct code path, in a single `test` block. Not many
  categorized blocks covering the same path from different angles.
- `zig build test` must be green before anything is called done — the full
  suite, not the stage you touched.

## Dependencies and tooling

Duni has a **zero-dependency policy** beyond the Zig toolchain. `wat2wasm` and
`node` are required to *run* compiled output and the `// run` cases, and they
are the only external tools. Adding a third needs a decision record.

Prefer the tool already in hand. A new script is a Zig file or a build step
before it is a new language in the repo.
