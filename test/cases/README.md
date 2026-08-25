# Compiler case tests

Each `.duni` file here is one test. The program is at the top; the expected
result is the trailing `//` comment block (the footer). The harness
(`test/cases.zig`) discovers files automatically — adding a test is adding a
file. Subdirectories only prefix the case name; they carry no other meaning.

Duni has no comment syntax, so the footer is harness metadata: the compiler is
given a copy of the file with the footer stripped.

Run with `zig build test-cases`, one case with
`zig build test-cases -Dtest-filter=<substring>` (matched against e.g.
`wat/extern_call`). Each passing case prints `✓ <name>`; a failing case is
reported by the build runner with its name and an expected/found diff.

## `// wat` — golden compiler output

Compile and compare stdout to the golden WAT, byte for byte. The footer is the
directive, a bare `//` separator, then the golden output with each line
prefixed `// ` (a bare `//` is an empty line):

```
extern fn print(x number) number

print(43)

// wat
//
// (module
//   ...
// )
```

## `// run` — execute and check stdout

Compile, assemble with `wat2wasm`, execute with `node host.js`, compare
stdout. Each `expect_stdout=` line expects that text plus a newline, in order:

```
extern fn print(x number) number

print(6)

// run
// expect_stdout=6
```

`wat2wasm` and `node` are found on PATH, or passed with `-Dwat2wasm=<path>`
and `-Dnode=<path>`. When either is missing, `// run` cases are skipped and
the skip count is printed.

## `// error` — expected compile errors

The compiler must exit 1 and print exactly these diagnostics to stderr, byte
for byte. Same footer shape as `wat`: directive, bare `//` separator, then
the expected stderr. The compiler's input path (a machine-specific cache
path) is stripped from stderr before comparing, so expected lines start at
the colon: `:line:col: error: message`.

```
extern fn print(x number) number

print(1, 2)

// error
//
// :3:1: error: expected 1 argument(s), found 2
```

