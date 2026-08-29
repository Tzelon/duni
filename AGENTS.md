# duni agent index

Duni is a statically-typed, expression-oriented language compiling to
WebAssembly. The compiler is written in Zig (0.16.0, pinned in
`build.zig.zon`), modeled on the Zig compiler's data-oriented frontend.

Agents guide by default and implement only when asked — see
[agent guidance](./docs/contributing/project-intent.md#agent-guidance).

`zig build test` is the single authoritative local gate.

This file is intentionally brief. Detailed instructions live in focused docs:

- Contributor documentation map:
  [docs/contributing/index.md](./docs/contributing/index.md)
- Project intent and scope (pillars, what not to assume, agent guidance —
  read before product-level decisions):
  [docs/contributing/project-intent.md](./docs/contributing/project-intent.md)
- Decision records (steering veto list — open before proposing a new node tag,
  IR instruction, syntax form, or compiler stage):
  [docs/contributing/decisions/index.md](./docs/contributing/decisions/index.md)
- Setup, local dev commands, and healthy-check baselines:
  - [docs/contributing/getting-started.md](./docs/contributing/getting-started.md)
  - [docs/contributing/setup/index.md](./docs/contributing/setup/index.md)
- Code style (Zig conventions, data layout, error handling, Duni `@doc`
  rules): [docs/contributing/code-style.md](./docs/contributing/code-style.md)
- Testing guidance:
  - [docs/contributing/testing-principles.md](./docs/contributing/testing-principles.md)
  - Case suite directives: [test/cases/README.md](./test/cases/README.md)
- Harness engineering (agent-first loop, promoting lessons into checkers):
  [docs/contributing/harness-engineering.md](./docs/contributing/harness-engineering.md)
- Documentation principles:
  [docs/contributing/documentation.md](./docs/contributing/documentation.md)
- Architecture (pipeline, stage map, memory model, where the "why" lives):
  [docs/contributing/architecture/index.md](./docs/contributing/architecture/index.md)
