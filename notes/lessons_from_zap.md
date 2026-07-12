# Lessons from Zap

## Context (re-orient future-you)
Zap is Brian Cardarella's Elixir-flavored language at `~/Projects/Langs/zap`.
~240k LOC Zig + ~5.7k LOC Zap stdlib, ARC + escape analysis, hygienic macros,
backend delegates to a fork of Zig 0.16 (`~/projects/zig`) via C-ABI emitting
ZIR. It's roughly what Duni could grow into; many of its choices are good,
some are taxes Duni shouldn't pay. Duni's targets: **WASM** + **Elixir-style
macros**. These notes are the cherry-picked takeaways.

## Architecture snapshot
| | Zap | Duni now |
|---|---|---|
| Parser | recursive descent, 9,411 L, many context flags | RD + Pratt, 166 L |
| AST | heap nodes w/ provenance + scope sets (`src/ast.zig`) | MultiArrayList |
| IRs | HIR → IR → ZIR + many passes | DIR → AIR |
| Memory | ARC, 9 `arc_*` files, escape lattice, Perceus reuse | none yet |
| Backend | C-ABI into forked Zig (`src/zir_builder.zig`, 11.9k L) | none |
| Runtime | `src/runtime.zig`, 22.7k L | none |
| Stdlib | 76 `lib/*.zap` files, calls `:zig.*` at leaves | none |

---

## DO — macros (Elixir-style)

**Macros in the language, not the compiler.** Zap's `if`/`unless`/`and`/`or`/
`|>` live in `lib/kernel.zap:48-120` as `quote`/`unquote` lowering to `case`.
The compiler doesn't know what `if` is. Your homoiconic AST plan in
`ast_structure.md` already aims here — commit to it.

**Expansion provenance per node.** `src/ast.zig:109-137` carries `ExpansionInfo`
with a parent chain so errors inside expanded code can point at the macro call
site. Elixir gives you `__CALLER__` for the same reason. Skip this and every
macro error looks like it happened inside `Kernel`.

**Pick a hygiene model before macros land.** Zap uses Flatt-2016 scope sets
(`src/ast.zig:50-54`). Elixir uses counter-gensym + context. Either works.
Retrofitting hygiene = rewrite, not extension.

## DON'T — macros

**Don't let the data-oriented AST survive contact with macro expansion.**
Zig-style `MultiArrayList(Node)` + flat `extra_data` is great for fixed-tree
compilation, hostile to tree rewriting. Zap uses heap-allocated rich nodes
*because* of macros. Options:
1. Convert MultiArrayList → tree of heap nodes at the macro-expansion
   boundary (Zap-style), flatten back after.
2. Reserve growable `extra_data` and accept arena-monotonic expansion.

**This is the one architectural decision you can't defer.** Pick before
macros land.

---

## DO — non-macro

**Errors as IR, formatted at the edge.** Zap splits this across
`error_codes.zig`, `error_ir.zig` (244 L), `error_format.zig` (212 L),
`error_json.zig`, `diagnostics.zig` (1,756 L). Errors are structured data;
formatting happens once at output. Gets you LSP-friendly JSON, test-assertable
error codes, multi-format consumers. If you `writer.print("expected x, got y")`
from sema, you've locked yourself out of all three.

**CTFE as a real subsystem.** `src/ctfe.zig` is 9,102 L. Compile-time eval is
where const-fold, type-level compute, baked-in config, and macro-result eval
all live. For WASM it's a force multiplier — bytes you don't ship. Sketch
the boundary in AIR now even if the implementation is two opcodes deep.

**Capability/target matrix from day one.** `capability_inference.zig` (473 L)
+ `target_capability_audit.zig`. WASM has many tiers — baseline / WASI p1 / p2
/ WASM-GC / threads / SIMD / tail-calls / EH — and real programs straddle them.
Rule: every primitive declares the capability it requires; compiler refuses to
lower a program whose required-set isn't a subset of target's available-set.
Without it, you scatter `if (target == ...)` everywhere.

**Collector pass before sema.** `collector.zig` (1,667 L) walks the AST
gathering top-level decls before semantic analysis. Enables forward refs and
mutual recursion. `slime.duni` already needs this — its functions call each
other freely. Wire collector between Parse and Sema before Sema grows opinions
about declaration order.

**Stdlib in Duni, primitives via FFI escape hatch.** Zap's 76 `lib/*.zap`
call `:zig.IO.println(...)` only at the leaves. For WASM, same pattern with
`:host.*`. Discipline matters: once the compiler knows about `String.length`,
it never gives that knowledge back.

**Test framework in your own language.** Zap's Zest lives in `lib/zest/`.
Eating own dogfood for tests finds ergonomics gaps fast and gives you a
working program-of-nontrivial-size during bringup.

**Source maps planned before backend lands.** `addr2line.zig` exists because
traces need to point at user code. WASM has **no native stack traces** — DWARF
custom sections or sidecar source map, decide before codegen.

## DON'T — non-macro

**Don't fork your backend.** Zap depends on a fork of Zig 0.16 talking C-ABI
via `src/zir_builder.zig` (11.9k L). Every Zig update is reconciliation work.
For WASM you have cheaper paths:
- **Binaryen** (C API, optimizes for you)
- **Hand-rolled emitter** (~50 opcodes you care about, ~2k LOC competent)
- **wasm-tools / walrus** as reference

WASM bytecode is much simpler than ZIR.

**Don't ship a memory model before you have programs to run.** Zap has 9
`arc_*` files + `escape_lattice.zig` + `generalized_escape.zig` +
`lambda_sets.zig`. Research-tier; bloated parser and IR by 100x vs Duni. For
WASM: target **WASM-GC** (V8 + SpiderMonkey ship it) and let the host trace,
or trivial RC on linear memory. Optimize only when profiling demands.

**Don't write a 22k-line runtime in Zig.** Zap's `runtime.zig` is huge because
native targets do everything themselves. WASM hands you a runtime — the host.
Push primitives to host `import`s, write the rest in Duni, keep Zig glue in
the low thousands of lines. Your `:host.*` table *is* your runtime.

**Don't accrete IR stages speculatively.** Zap's parse→collect→desugar→
typecheck→HIR→monomorphize→IR→passes→ZIR exists for real reasons *now* but
constrains everything downstream. DIR→AIR is right-sized. Third IR only when
a specific lowering pain forces it.

**Don't accrete parser context flags.** Zap's parser has
`disable_trailing_block`, `case_arm_pattern_context`, `script_mode`, etc. —
each one a grammar ambiguity resolved by threading state. Every new syntax
form, ask "does this force a context flag?" before adding.

**Don't bake string errors into the compiler.** Inverse of errors-as-IR.
Structured `Diagnostic` always; format at the edge.

**Don't reject programs in the parser based on target.** `frontend_policy.zig`
keeps target-specific restrictions out of parsing. "u128 not on this tier" =
capability check, not syntax error. Otherwise same compiler binary can't
cleanly serve multiple WASM tiers.

**Don't write incremental compilation early.** Zap has `incremental_graph.zig`
+ `build_cache.zig` because Zap programs are big. Duni won't hit this for
years and incrementality colors every API it touches (content-addressing,
input declaration). Add when build times actually hurt.

**Don't write a CPS transform or trampoline for tail calls.** `slime.duni:39`
already uses them. WASM tail-call proposal ships in V8 / SpiderMonkey /
wasmtime. Emit `return_call` / `return_call_indirect` directly; require the
tier.

---

## The one decision to make before AIR ossifies
**WASM-GC vs linear memory.** Different worlds:
- **WASM-GC**: host traces, types survive into runtime, AIR threads richer
  type info, no allocator code, struct/array as host primitives.
- **Linear memory**: you own allocator and layout, types erased at runtime,
  smaller deployable surface today, works on every WASM host.

Pick before AIR grows opinions about heap representation. Wrong-then-rewrite
cost is enormous. WASM-GC is the modern answer if you can stomach requiring
a baseline of GC-capable hosts.

## Quick map of Zap files worth re-reading later
- `src/ast.zig` — provenance, scope sets, NodeMeta shape
- `lib/kernel.zap` — macros-in-language done right
- `src/diagnostics.zig` + `src/error_*.zig` — error IR layout
- `src/ctfe.zig` — CTFE boundary and depth
- `src/capability_inference.zig` + `src/target_capability_audit.zig` —
  capability matrix
- `src/collector.zig` — pre-sema decl gather
- `lib/io.zap` (32) — `:zig.*` escape hatch pattern
- `src/zir_builder.zig` — C-ABI shape (cautionary tale, not template)
