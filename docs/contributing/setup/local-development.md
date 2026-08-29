# Local development

Commands for building, running, and testing the compiler. Run them from the repo
root.

## Build

```bash
zig build            # builds zig-out/bin/duni
```

## Run the compiler

`duni` reads a source file, runs the whole pipeline, and prints the resulting
WAT to stdout. It does not assemble or execute anything.

```bash
zig build run                     # no args: starts the REPL
zig build run -- example.duni     # prints WAT for a file
```

## Run a Duni program end to end

`./run-duni` does the three steps a program needs — compile to WAT, assemble to
wasm with `wat2wasm`, execute with `node host.js`:

```bash
./run-duni path/to/file.duni
```

Intermediate files land in `duni-out/` (`duni.wat`, `duni.wasm`).

Files under `test/cases/` cannot be run this way. Duni has no comment syntax, so
their trailing `//` footer is not valid source — the harness strips it before
handing the file to the compiler. For the same reason `slime.duni` and other
sketches in the repo root do not compile: they are written in the language Duni
is becoming, not the one it accepts today.

Execution needs a host because a Duni program reaches the outside world only
through `extern fn` imports. `host.js` is that host, and it supplies exactly two
functions today, both under the `host` module:

- `print(x)` — writes `x` and a newline to stdout, returns `x`
- `sub(a, b)` — returns `a - b`; exists so argument order is observable

A program that declares an `extern fn` `host.js` doesn't provide will fail at
instantiation, not at compile time. Add it to `host.js` alongside the case that
needs it. Note that `wasmtime` is not a substitute — it cannot supply the `host`
import.

## Tests

```bash
zig build test                  # everything: unit tests + case suite
zig build test-unit             # only the in-file `test` blocks
zig build test-cases            # only the data-driven cases (test/cases/)
zig build test --summary all    # per-step output
```

Run one case by substring:

```bash
zig build test-cases -Dtest-filter=arithmetic
```

Run a single unit test by name:

```bash
zig test src/Sema.zig --test-filter "<name>"
```

Adding a regression test means adding one `.duni` file under `test/cases/` with
a trailing comment block declaring the expected result — no Zig code. See
`test/cases/README.md` for the directives.

## Before committing

```bash
zig fmt src/
zig build test
```

Git tracks `src/ast.zig` and `src/dir.zig` in lowercase on a case-insensitive
filesystem, so `git add src/Ast.zig` can silently miss. Stage with `git add src/`
and check `git show --stat`.
