# Architecture

The compiler is a one-direction pipeline; each stage has one job and hands a
flat, data-oriented structure to the next (see the
[compiler core pillars](../project-intent.md#compiler-core-pillars)):

```
Text -> Scanner => tokens -> Parse => Ast -> AstGen => Dir -> Sema => Air -> WatGen => WAT
```

The frontend is closely modeled on the Zig compiler's own design — flat
`MultiArrayList`s and typed indices rather than a tree of heap-allocated node
objects. Variable-length data goes in a flat `extra_data: []u32` array
referenced by ranges, never inline in a node (see
[code style — data layout](../code-style.md#data-layout)). Understanding that
pattern is the key to working here.

## Stage map

- **`src/scanner.zig`** — hand-written lexer driven by a labeled-switch state
  machine (`continue :state`). `Token.Tag` is the full token enum;
  `Token.lexeme`/`symbol` map tags back to text for error rendering.
- **`src/ast.zig`** (+ `src/Ast/Node.zig`, `src/Ast/Print.zig`) — the `Ast`
  struct and its `Node` representation. `Ast.parse` is the entry point: it
  tokenizes into a `MultiArrayList`, runs `Parse.parseRoot`, and returns an
  owned `Ast`. Node 0 is always the root. `Node.Index`/`OptionalIndex`/`Offset`
  are distinct enum types so index kinds cannot be mixed up. Consumers walk the
  AST from standalone visitor modules, not methods on `Ast`.
- **`src/Parse.zig`** — the parser state that becomes an `Ast` when
  `parseRoot` finishes. Expression parsing is Pratt / precedence-climbing
  (`parsePrecedence` + the `ParseRule` table); declarations and statements are
  recursive descent. Errors are **recoverable** (`warn*` appends and parsing
  resyncs) or **fatal** (`fail*` appends and unwinds with `error.ParseError`).
- **`src/AstGen.zig`** (+ `src/AstGen/Scope.zig`, `src/AstGen/scratch.zig`) —
  walks the AST and lowers it into `Dir` instructions via `AstGen.generate`.
- **`src/dir.zig`** — Duni IR ("DIR"): untyped instructions produced by
  `AstGen`, consumed by `Sema`. `src/print_dir.zig` renders it one instruction
  per line for debugging.
- **`src/Sema.zig`** (+ `src/Sema/Air.zig`, `src/Sema/arith.zig`) — semantic
  analysis. `Sema.analyze` walks the `Dir` and produces `Air` (typed, analyzed
  IR); `arith.zig` holds the arithmetic helpers.
- **`src/InternPool.zig`**, **`src/Type.zig`**, **`src/Value.zig`**,
  **`src/string.zig`** — types and values are canonically a single 32-bit
  index into the `InternPool`, shared by `Sema` and `WatGen` and owned by
  `main`. `Type` and `Value` are views that add the methods applicable to each;
  `string.zig` interns strings.
- **`src/WatGen.zig`** — emits WebAssembly text (WAT) from the `Air` plus the
  `InternPool`. The only backend — see
  [decision 0002](../decisions/0002-wat-only-backend.md).
- **`src/main.zig`** — CLI entry point: REPL, or run a file through the whole
  pipeline and print the resulting WAT.
- **`src/root.zig`** — the library module root (`addModule("duni", ...)`).
- **`src/ref_src/`**, **`src/ref_src_2/`** — earlier iterations kept for
  reference; not part of the build.

## Memory model

`Ast.parse` takes a `gpa` allocator and returns an `Ast` that owns its
`tokens`, `nodes`, `extra_data`, and `errors`; callers must call
`tree.deinit(gpa)`. The `Parse` value itself is scratch state (note `scratch`,
a reusable node list) and is `deinit`'d inside `Ast.parse`. Ownership
conventions are in [code style — memory](../code-style.md#memory).

## Where the "why" lives

- **`notes/`** — design notes and prior-art writeups. **Check here first when
  looking for the reasoning behind a decision** (AST shape, AstGen lowering,
  error reporting, name resolution, Sema, number/string literals, lessons from
  Zap). The code says *what*; these notes say *why*.
- **`grammar.y`** — the destination grammar. It describes the language Duni is
  becoming, not what the parser accepts today (see
  [what not to assume](../project-intent.md#what-not-to-assume)).
- [Decision records](../decisions/index.md) — product-shaped nos and durable
  constraints.
