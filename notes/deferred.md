# Deferred decisions — B½ session ledger (2026-08-03)

Things considered during the module-instruction / extern-fn work and
deliberately skipped. Each entry records what was skipped, why, and the
trigger that should revive it. Context: the module encoding this session
produced is `module_decl` — an `.extended` instruction at index 0
(`main_module_inst`) whose payload is `ModuleDecl{src_node, body_len}` +
trailing ordered body. A Duni module is a script today: its payload is a
body to execute, not a decl list to resolve (see the setStruct comparison
below).

## Language / semantics

- **Require `fn main`.** Decided destination, not current state. WASM is
  neutral (it only needs an exported function; the start section is
  `[] -> []` init-only; WASI convention is `_start`). Script mode stays
  because the whole B½/B staging depends on the implicit main body being
  analyzable by today's Sema.
  **Trigger:** the first time someone asks whether a fn body can reference
  a top-level bind (`x = 1` … `fn f() number { x }`). That question forces
  globals/capture design under script mode — instead of answering it,
  switch to `fn main`. Lands naturally at the namespaces arc. Do NOT build
  top-level-binds-as-wasm-globals; that's the expensive fork.
- **`void` type.** No `Ref`/InternPool entry exists. `extern fn print(...)
  number` is the honest v1. Deciding void means deciding what a
  void-returning call yields in an expression language where blocks have
  values.
  **Trigger:** wanting `print`'s type to stop lying.
- **Extern module string** (`extern "wasi_snapshot_preview1" fn ...`).
  v1 hardcodes module `"host"` in WatGen's import emission. The string
  gets a slot next to the proto when needed (Zig's `lib_name` analog).
  **Trigger:** first WASI-shaped interface whose module name we don't
  control.
- **Fns as values / non-identifier callees.** Parser rejects non-identifier
  callees (`expected_callee`); `localVarRef` skips the namespace (a fn name
  is not an expression). Both are v1 simplifications.
  **Trigger:** first-class functions / closures. The parser check moves to
  AstGen when its error reporting exists.
- **Multiline call arguments.** The arg loop doesn't skip `.newline`.
  Span machinery is already safe for it (stored closers), so this is
  parser-only whenever wanted.

## Dir / module encoding

- **Decl list in the module payload.** Today decls (externs, next commit)
  are *body* instructions; `decls_len` was removed everywhere because a
  count without a list is a lie in the encoding. The namespaces arc moves
  decls out of the body into a trailing decl list: `Small` gets its first
  real flag (`has_decls_len`), `scanContainer` returns a count again, and
  `setModule` grows toward Zig's `setStruct` (conditional lens, caller-
  assembled remaining). `Dir.mainBody()` is the single decoder — layout
  changes happen there, nowhere else.
- **`fields_hash` / `src_line` header fields** (Zig's StructDecl carries
  them). Serve incremental compilation and diagnostics line info.
  **Trigger:** their consumers (incremental arc, error rendering).
- **Nested containers.** `rootModuleDecl`'s reserve-then-fill composes at
  any depth (the reserve is relative, not hardcoded to 0), but
  `setModule` asserts `src_node == .root` and `mainBody` reads
  instruction 0. **Trigger:** module/struct syntax inside a file — restore
  Zig's parent-scope-walk assert then.

## AstGen machinery

- **Structured `Scratch`** (`addSlice` sub-slice reservation, `all()`,
  `reset()`). The plain `astgen.scratch: ArrayList(u32)` arrives with the
  externs commit (callExpr/externFnDecl trailing refs — args can't stream
  into `extra` because lowering them writes other payloads in between).
  The structured type pays off only when one payload has two-plus
  variable-sized trailing pieces built per-member.
  **Trigger:** module decl-list + body, fields, or multi-clause heads.
  (`appendBodyWithFixups` never comes — Dir has no ref-table fixups.)
- **Error reporting phase 1.** `scanContainer` keeps Zig's structure
  (NameEntry chain for multi-note duplicate diagnostics, shadow walk) with
  `appendError*`/`errNote*` calls commented out and `log.warn` +
  `AnalysisFail` placeholders. The placeholder list keeps growing:
  duplicate fn name, missing fn name, shadowing, undeclared identifier,
  unsupported pattern, swallowed string-escape errors, negative zero.
  **Trigger:** scheduled — right after B½ lands. The commented calls are
  the implementation checklist.
- **Shadow walk in `scanContainer` is dormant** — the root namespace's
  parent is always `Top`, so the `.local_val` arm never fires.
  **Trigger:** containers nested inside function bodies.
- **Two arenas** (`arena` for error-path NameEntries, `scope_arena` for
  scopes). Consolidate to one before more allocations pick sides.
- **`full.FnProto` / `fullCall` AST view structs.** Per-piece accessors
  were removed (inline decoding at use sites); the bundled view returns
  when AstGen lowers real fns and needs param iteration with name-token
  recovery (Zig's `FnProto.iterate`).
  **Trigger:** stage B (`fnDeclInner` equivalent).

## Sema / InternPool

- **Zig's `Nav` (named addressable value).** `InternPool.zig:544` in the
  Zig tree. It's Zig's decl-level identity — the slot a source declaration
  resolves to — and it carries machinery Duni doesn't have: two-state lazy
  resolution (`analysis: ?{namespace, zir_index, wanted}` vs
  `resolved: ?Resolved`, for incremental rebuilds), a `namespace` +
  fully-qualified `fqn`, per-decl backend attributes (align, linksection,
  addrspace, threadlocal, const), and generic instantiation
  (`generic_owner`). Zig splits the decl (`Nav`) from the value it resolves
  to (`Key.Extern`) because a Nav can be a var / fn / generic instance.
  Duni collapses that: the P2 extern **value** (`Key.ExternFunc{ty, name,
  lib_name}`) is self-contained (WatGen emits `(import "host" "print" …)`
  from it alone), and the S1 `decls` map (`NullTerminatedString → Index`)
  *is* the decl layer — eager, whole-program, single-module. `name` living
  in both the map key and the ExternFunc value is intentional (Zig does the
  same); the value must stand alone for codegen. A Nav here would be Zig's
  premise — lazy, incremental, multi-namespace, backend-attributed — without
  Duni's requirements.
  **Trigger:** the first of incremental compilation, real
  namespaces/modules, per-decl backend attributes, or generics — each
  parked elsewhere in this ledger. Whichever lands first needs a decl-slot
  richer than a name→Index map; that's when a Nav-like layer earns its place.

## Parser / formatter

- **`call_comma` tag split.** With closers stored in the AST, trailing
  comma no longer affects spans — the tag exists purely to preserve the
  user's one-line/multi-line intent.
  **Trigger:** a Duni formatter.

## Runtime / tooling

- **WASI `_start` wrapper** so `wasmtime out.wasm` runs bare (today main
  returns f64 → `--invoke` territory).
  **Trigger:** CLI/run story.
