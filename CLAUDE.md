# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Duni is an early-stage compiler for a small statically-typed language, written in
Zig. It is a learning/in-progress project: the scanner and parser are functional,
later pipeline stages (AstGen, Sema, bytecode) are stubs.

## Toolchain

Requires Zig 0.16.0 (pinned via `minimum_zig_version` in `build.zig.zon`). The
codebase uses the post-0.15 `std.Io` API (e.g. `std.Io.File`, `init: std.process.Init`
in `main`), so older Zig versions will not compile it.

## Commands

- `zig build` — compile the `duni` executable to `zig-out/bin/duni`.
- `zig build run` — build and run; with no args this starts the REPL.
- `zig build run -- <file.duni>` — parse a source file (e.g. `example.duni`).
- `zig build test` — run all tests.
- `zig build test --summary all` — run tests with per-step output.
- `zig test src/<file>.zig --test-filter "<name>"` — run a single test by name.

## Architecture

The intended pipeline (see `src/README.md`):

```
Text -> Scanner => tokens -> Parser => AST -> AstGen => IR -> Sema => Bytecode
```

The frontend is closely modeled on the Zig compiler's own design — a
data-oriented AST rather than a tree of heap-allocated node objects. Understanding
that pattern is the key to working here:

- **`src/scanner.zig`** — `Scanner` is a hand-written lexer driven by a labeled-switch
  state machine (`continue :state`). `Token.Tag` is the full token enum;
  `Token.lexeme`/`symbol` map tags back to text for error rendering.
- **`src/ast.zig`** — defines the `Ast` struct and its `Node` representation.
  `Ast.parse` is the entry point: it tokenizes into a `MultiArrayList`, runs the
  `Parser`, and returns an owned `Ast`. Nodes live in a `MultiArrayList(Node)`;
  each `Node` is a tag + `main_token` + an 8-byte `Data` union. Node 0 is always
  the `root`. Variable-length data (parameter lists, statement lists) is *not*
  stored inline — it goes into the flat `extra_data: []u32` array and is
  referenced by `SubRange`/`ExtraIndex`. `Node.Index`/`OptionalIndex`/`Offset`
  are distinct enum types to keep index kinds from being mixed up.
- **`src/parser.zig`** — `Parser` builds the AST. It is a hybrid:
  - Top-level/declaration parsing is recursive descent (`parseContainerMembers`,
    `funDecl`, `parseParamDeclList`, `parseBlock`).
  - Expression parsing is Pratt / precedence-climbing (`parsePrecedence` +
    the `getRule` `ParseRule` table + the `Precedence` enum), the
    Crafting-Interpreters style.
  - Error handling distinguishes **recoverable** errors — `warn*` appends to
    `errors` and parsing continues — from **fatal** ones — `fail*` returns
    `error.ParseError`. `expect*` wraps `parse*` to turn a missing node into a
    fatal error. Errors are surfaced via `renderError`/`tokenLocation`.
- **`src/AstGen.zig`** — walks the AST (visitor pattern) to lower it toward IR.
  Currently only prints nodes; most node tags hit the `unhandled` panic.
- **`src/ir.zig`**, **`src/ErrorBundle.zig`** — stubs / not yet wired in.
- **`src/main.zig`** — CLI entry point: REPL vs. `runFile`. `runFile` reads a
  file, calls `Ast.parse`, and prints any collected errors.
- **`src/root.zig`** — the library module root (`addModule("duni", ...)`).
  Currently boilerplate; `main.zig` imports the frontend via relative paths,
  not through this module.
- **`grammar.y`** — the informal language grammar (BNF-ish), the reference for
  what the parser should accept.

## Memory model

`Ast.parse` takes a `gpa` allocator and returns an `Ast` that owns its `tokens`,
`nodes`, `extra_data`, and `errors`; callers must call `tree.deinit(gpa)`. The
`Parser` itself is scratch state (note `scratch`, an arena-like reusable node
list) and is `deinit`'d inside `parse`.

## Gotchas

- `src/parser_test.zig` is stale: it calls `Parser.init(source, allocator)`, an
  API that no longer exists (the `Parser` is now built as a struct literal inside
  `Ast.parse`). It is not currently reached by `zig build test` — only 2 trivial
  tests run. Update it to the current API before relying on it.
- `build.zig.old` and `test.zig` are leftover scratch files, not part of the build.
