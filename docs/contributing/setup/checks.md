# Checks

How to verify the environment is complete and the suite really ran.

## Tools

```bash
zig --version        # expect 0.16.x
wat2wasm --version   # wabt — required to assemble WAT
node --version       # required to execute wasm via host.js
```

Zig alone is enough to build the compiler and print WAT. `wat2wasm` and `node`
are needed to *execute* anything, which includes the `// run` cases in the test
suite.

If either tool is not on `PATH`, pass it explicitly:

```bash
zig build test -Dwat2wasm=/path/to/wat2wasm -Dnode=/path/to/node
```

## The suite

```bash
zig build test --summary all
```

**Check the output for this line:**

```
test-cases: skipped N `// run` case(s); pass -Dwat2wasm=<path> and -Dnode=<path> ...
```

When `wat2wasm` or `node` is missing, the harness skips every execution case and
still reports success. A green run with that warning means nothing was ever
executed — the compiler was only checked for the WAT it printed. Treat the
warning as a failure.

## Formatting

```bash
zig fmt --check src/
```

## What a healthy run looks like

- `zig build` produces `zig-out/bin/duni`.
- `zig build test --summary all` passes with no skip warning.
- A minimal program compiles, assembles, and runs:

  ```bash
  printf 'extern fn print(x number) number\n\nprint(1 + 2 * 3)\n' > /tmp/check.duni
  ./run-duni /tmp/check.duni      # prints 7
  ```
