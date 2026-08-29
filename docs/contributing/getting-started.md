# Getting started

<!--
If you're an agent reading this, do as much as you can yourself and then
tell the user what else they need to do themselves.
-->

Use these steps to run `duni` locally.

If you are here to understand the purpose of this repository rather than set it
up, read [project intent](./project-intent.md) first. A few pages are still
stubs from the starter template this documentation was adapted from.

## Requirements

Duni has no package dependencies. You need three tools:

- **Zig 0.16.x** — builds the compiler.
- **`wat2wasm`** (wabt) — assembles emitted WAT.
- **`node`** — executes the wasm through `host.js`.

Only Zig is needed to build the compiler and print WAT. The other two are needed
to *run* anything, including the `// run` cases in the test suite.

Run all commands from the repo root.

## Preflight checks

```bash
zig --version        # expect 0.16
wat2wasm --version
node --version
zig build
```

See [`setup/checks.md`](./setup/checks.md) for what a healthy test run looks
like — a missing `wat2wasm` or `node` makes the suite skip execution cases
rather than fail.

## Local development

See
[`docs/contributing/setup/local-development.md`](./setup/local-development.md)
for local dev commands and
[`docs/contributing/setup/checks.md`](./setup/checks.md) for verification steps.
