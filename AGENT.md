# IMPORTANT

- You provider guidance of how to build the compiler, do not implement anything unless asked
- Do not be wordy, not need to use jargon also, keep it simple.

## What this is

Duni is an early-stage compiler for statically-typed language, written in
Zig. Duni compiles into WASM.

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
Text -> Scanner => tokens -> Parse => Ast -> AstGen => Dir -> Sema => Air -> WatGen
```

The frontend is closely modeled on the Zig compiler's own design — a
data-oriented AST rather than a tree of heap-allocated node objects. Understanding
that pattern is the key to working here:

- **`src/scanner.zig`** — `Scanner` is a hand-written lexer driven by a labeled-switch
  state machine (`continue :state`). `Token.Tag` is the full token enum;
  `Token.lexeme`/`symbol` map tags back to text for error rendering.
- **`src/Ast.zig`** — defines the `Ast` struct and its `Node` representation.
  `Ast.parse` is the entry point: it tokenizes into a `MultiArrayList`, runs
  `Parse.parseRoot`, and returns an owned `Ast`. Nodes live in a `MultiArrayList(Node)`;
  each `Node` is a tag + `main_token` + an 8-byte `Data` union. Node 0 is always
  the `root`. Variable-length data (parameter lists, statement lists) is _not_
  stored inline — it goes into the flat `extra_data: []u32` array and is
  referenced by `SubRange`/`ExtraIndex`. `Node.Index`/`OptionalIndex`/`Offset`
  are distinct enum types to keep index kinds from being mixed up.
- **`src/Parse.zig`** — `Parse` is the in-progress parser state that becomes an
  `Ast` once `parseRoot` finishes. The entry point is `parseRoot`, which seeds
  node 0 as `.root` and parses a single top-level expression into it.
  - Expression parsing is Pratt / precedence-climbing (`parsePrecedence` +
    the `getRule` `ParseRule` table + the `Precedence` enum), the
    Crafting-Interpreters style. Today only `.number_literal` has a rule wired
    up; the other tag arms are commented out as placeholders.
  - Declaration / statement parsing (containers, `fn`, blocks, etc.) is not
    implemented yet — there is no recursive-descent layer.
  - Error handling distinguishes **recoverable** errors — `warn*` appends to
    `errors` and parsing continues — from **fatal** ones — `failMsg` calls
    `warnMsg` then returns `error.ParseError`. There are no `expect*` helpers
    yet.
- **`src/AstGen.zig`** — walks the AST and lowers it into `Dir.Inst` instructions
  via `AstGen.generate`. Today only `.number_literal` is handled; other tags hit
  `unreachable` in the `expr` switch.
- **`src/Dir.zig`** — Duni IR ("DIR"): the post-AST lowering produced by
  `AstGen.generate` and consumed by `Sema.analyze`.
- **`src/Sema.zig`** — semantic analysis. `Sema.analyze` walks the `Dir` and
  produces an `Air` (analyzed IR), using an `InternPool` for deduplicated
  types/values.
- **`src/Sema/Air.zig`** — analyzed IR emitted by `Sema`; consumed by `WatGen`.
- **`src/Sema/InternPool.zig`** — intern pool for types/values shared across
  `Sema` and `WatGen`. Owned by `main`, threaded through both stages.
- **`src/WatGen.zig`** — final code generation. `WatGen.emit` takes the `Air`
  plus the `InternPool` and writes WebAssembly text (WAT) to a writer. This is
  the only codegen path.
- **`src/main.zig`** — CLI entry point: REPL vs. `runFile`. `runFile` reads a
  file and runs the whole pipeline — `Ast.parse` → `AstGen.generate` →
  `Sema.analyze` → `WatGen.emit` — printing the resulting WAT to stdout. Any
  parse errors are printed after Sema.
- **`src/root.zig`** — the library module root (`addModule("duni", ...)`).
  Mostly boilerplate (`add`, `printAnotherMessage`) with a `comptime` reference
  to `Sema.zig` so its tests are pulled in; `main.zig` imports the frontend via
  relative paths, not through this module.
- **`grammar.y`** — the informal language grammar (BNF-ish), the reference for
  what the parser should accept.
- **`notes/`** — design notes and prior-art writeups. **Check here first when
  looking for the reasoning behind a decision** (AST shape, AstGen lowering,
  error reporting, name resolution, Sema, number/string literals, ZIR, lessons
  from Zap). The code says *what*; these notes say *why*.

## Memory model

`Ast.parse` takes a `gpa` allocator and returns an `Ast` that owns its `tokens`,
`nodes`, `extra_data`, and `errors`; callers must call `tree.deinit(gpa)`. The
`Parse` value itself is scratch state (note `scratch`, an arena-like reusable
node list) and is `deinit`'d inside `Ast.parse`.

## No Workarounds, Hacks, or Shortcuts

**STRICTLY FORBIDDEN.** Never implement workarounds, hacks, temporary fixes, or shortcuts of any kind.
Every solution must be the correct, production-grade, long-term fix — regardless of how difficult, expensive, or time-consuming it is.
If a proper fix requires deep architectural changes across multiple files, ask before implement.
Cost and time are not concerns — correctness and quality are. If you find yourself writing a "temporary" fix, stop — and ask.

## Never compromise on code quality

When you have an option to finish a taks faster but implementing a short cut, a hack, or some lower quality solution never take this option.

## Duni is a Language — Implement Features in Duni Code

**THIS IS THE MOST IMPORTANT RULE. VIOLATIONS ARE UNACCEPTABLE.**

Duni is a general-purpose programming language. Features, behaviors, library functions, and language constructs MUST be implemented in Duni source code (`lib/*.duni`), NOT hardcoded in the Zig compiler (`src/*.zig`).

**NEVER hardcode Duni struct names, function names, or library behavior in the compiler.** The compiler is a general-purpose tool. It does not know about IO, String, Kernel, Map, or any other Duni struct.
If you find yourself writing a Duni struct name as a string literal in Zig source, you are doing it wrong. Stop, think, and ask.

**ALWAYS attempt the Duni solution first.** Before touching any Zig compiler code, ask: "Can this be done in Duni?" If the answer is "yes" or "maybe," do it in Duni.
If you think it can't be done in Duni, think harder. Research how Elixir solves it. Research how other languages solve it.
Only touch the compiler as a last resort for genuine language primitives (parsing, type system, ZIR emission).

**The only things that belong in Zig:**

- Lexer/parser syntax (tokens, AST nodes)
- Type system primitives (Bool, String, Atom, i64, etc.)
- Dir, Air, WatGen emission mechanics

**Everything else is Duni code:**

- Standard library functions (IO, String, Integer, etc.) — defined in `lib/*.duni`, call `:zig.` for primitives
- Macros (if, unless, and, or, sigils) — defined in `lib/kernel.duni`
- Test framework — defined in `lib/test/*.duni`
- Sigil implementations — defined as macros in Kernel
- Validation, error checking, behavior — Duni macros and functions

**Do not create unnecessary abstractions in Zig.**

## Documentation

**All public Duni declarations MUST have `@doc` attributes.** Every `struct`, `fn`, and `macro` in `lib/*.duni` files must have an `@doc` heredoc describing what it does. No exceptions.

## Duni Code Quality

- **Blank line after every heredoc closing `"""`**. The `"""` must be followed by an empty line before the next declaration or attribute. No exceptions.
- **`@doc` goes immediately before the declaration it documents**. Struct docs belong outside the struct, immediately before `pub struct Name {`; do not put the struct `@doc` inside the struct body.
- **All `@doc` attributes use heredoc `"""`**, even one-line docs, with a blank line between the closing `"""` and the documented declaration.
- **Always use descriptive names.** Never use short or cryptic variable names, parameter names, or helper names when writing new code. Prefer explicit names that make the code readable without extra context.

## Development Workflow

_NEVER_ change old migrations that are already in git history.
_ALWAYS_ run the entire test suite before declaring any work is complete.
_ALWAYS_ TDD: write failing tests first, implement minimum code to pass, run `zig build test` locally, push only when green.

**No fallbacks.** When refactoring, fully commit to the new approach. Remove old code entirely. If the new approach fails, that's a bug to surface, not hide.

## Code Generation

**Duni ALWAYS lowers to WAT.** The only code generation path is `src/WatGen.zig`
