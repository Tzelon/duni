# TODO

## Next arcs

- **wasmtime round-trip:** the emitted module imports `host.print`, so
  `wasmtime` can't run it without a host shim. Stand up a tiny host (or switch
  to a WASI `_start` returning the value) so codegen is validated by
  _execution_, not just `wat2wasm`. (WASI `_start` parked in
  `notes/deferred.md`.)
- **Runtime block path — landed** (control-flow arc, stage B): Air has
  structured `block`/`cond_br`/`br` with per-body instruction collection
  (`Sema.Block`), one merge point per block. Early `return`/`break`/
  `continue` build on that machinery when they arrive; `match`
  compilation plugs into the same substrate.
- **Tail calls — landed** (`notes/tail_calls.md`): every call in tail
  position emits `return_call`; unbounded loops-as-recursion work
  (run/tail_loop drives 1M iterations, self and mutual). The harness
  passes `wat2wasm --enable-tail-call`; wasm tail calls are a minimum
  engine requirement of the language.

## Error reporting — phase 1

Placeholder `log.warn`s with no source location; design in
`notes/astgen_error_reporting.md`. The commented `appendError*` /
`addFailedDeclaration` calls are the checklist.

- **AstGen:** "use of undeclared identifier" (`localVarRef`); "unsupported
  pattern" (`bind`, non-identifier lhs); string-literal escape errors
  (`parseStrLit` — `failWithStrLitError` commented out, errors currently
  _swallowed_, not even failing).
- **Sema decls:** missing / duplicate fn name, undeclared type, the
  `boooooom` placeholder in `fnDecl`; the arity mismatch + int-doesn't-fit
  `log.warn`s in `analyzeCall` / `coerceIntToFloat`.

## Strings arc — remaining

- Sema operators: concat / equality / compare — open design questions in
  `notes/string_literals.md` (pick the concat operator, define comparison).
- Scanner escape sequences (`\"`, `\n`, `\xNN`); `parseStrLit` is ready, the
  scanner never delivers escapes (`\` is an ordinary byte today).
- Runtime-constructed strings (heap/GC) and the cross-function ABI.
- Host-side test runner that decodes `(ptr, len)` so tests assert on text.

## Quality follow-ups (no behavior change)

- `print_dir.writeStrTok` reads `data.str` but is dispatched for `.decl_val`,
  whose data is `str_tok` — wrong union variant if reached.
- `if (maybe_lhs_val) |v|` nesting in `analyzeArithmetic` →
  `orelse return error.AnalysisFail`.
- `inst_map.putAssumeCapacity` → `putAssumeCapacityNoClobber`.
- Reserved tags `int_u32` / `int_i32` have no producer — drop or implement
  with sized types.
- Trim stale `ty` mentions in `arith.add/sub/mul/div` doc comments.
- `CallArgsInfo.dir_call` still carries `bound_arg` / `call_inst` (method /
  RLS fields) that are always `.none` / unused — drop when method-call syntax
  is definitively ruled out, or wire up if it isn't.

## Parked

Moved to `notes/deferred.md` — each entry records why it was skipped and the
trigger that revives it. Highlights: `fn main` as the decided end state, `void`
type, extern module strings, decl list in the module payload, structured
`Scratch`, `call_comma`, WASI `_start`.
