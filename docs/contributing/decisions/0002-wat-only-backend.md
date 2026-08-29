# 0002: WAT is the only backend

- **Status:** draft <!-- accepted | superseded by [NNNN](./NNNN-slug.md) -->
- **Date:** 2026-08-28

## Context

A compiler can grow backends easily: native code via LLVM, a C backend, direct
WASM binary emission, an interpreter for the REPL. Each one is a second
definition of what a Duni program means, and each one has to be kept correct as
the language changes.

## Decision

`src/WatGen.zig` emits WebAssembly text (WAT), and that is the only code
generation path. Programs run by handing the WAT to a host (`host.js`,
`run-duni`).

## Consequences

Output is text, so tests can assert on it directly — `test/cases/wat/` compares
emitted WAT, and `test/cases/run/` executes it. Debugging codegen means reading
the output, not a disassembler.

The costs: an external toolchain step to get from WAT to a module, no native
target, and no path to custom sections or size-optimized output without
switching to binary emission.

**Revisit if:** binary WASM emission is needed for something WAT cannot express.
That is a change of output format, not the addition of a second backend — WAT
would be replaced, not joined.
