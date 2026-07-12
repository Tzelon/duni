# Duni AstGen error reporting

## How it should work

When AstGen meets input the AST permits but the language rejects — `1__2`,
`-0`, an overflowing literal, a float where Sema expects an integer later —
it needs to:

1. **Record** a structured error tied to a source location (token, optional
   byte-offset within the token).
2. **Continue** when the error is recoverable (analogue of the parser's
   recoverable model), or **abort** the current expression with
   `error.AnalysisFail` when it isn't.
3. **Render** the accumulated errors at the end of `generate` against the
   original source bytes, so the user sees `line:col: msg`, not `token 17`.

The API surface AstGen calls (already used at call sites today):

```
failTok(token, fmt, args)                    -> InnerError       // hard fail at a token
failOff(token, offset, fmt, args)            -> InnerError       // hard fail at byte offset within a token
failTokNotes(token, fmt, args, notes)        -> InnerError       // hard fail with attached notes
errNoteTok(token, fmt, args)                 -> !Note            // build one note; passed to failTokNotes
```

`InnerError = error{ OutOfMemory, AnalysisFail }`. Anything that returns
`InnerError` is announcing "I might have appended a diagnostic and bailed."
`errNoteTok` returns the note object; only the surrounding `fail*Notes` call
actually emits and frees.

`Dir` should carry the rendered diagnostics out — same shape as
`Ast.errors: []const Error`. Caller of `generate` decides whether to render
them, ignore them, or rely on `error.AnalysisFail` already having bubbled up.

## What it is doing now

The structured system is still unbuilt (no `fail*` methods, no
`compile_errors` field, no `Dir.errors`, no renderer), but the error *paths*
are now live and tested:

- `-0` integer literal: reachable (the negation fold re-enters
  `numberLiteral` with `.negative`), rejected via
  `std.log.warn` + `error.AnalysisFail`, pinned by an AstGen test.
- `.failure` from `parseNumberLiteral`: one generic warn + `AnalysisFail`,
  no per-variant messages yet.
- Sema has grown its own message-less `AnalysisFail` sites (integer and
  float division by zero) that will want the same machinery — or its Sema
  analogue — once it exists.

**Why `log.warn` and not `log.err`:** the Zig test runner fails any run in
which a test logged at error level, even if all tests pass. Tests that
exercise error paths therefore poison a green suite. This is the interim
hack the structured system replaces — errors accumulate as data, tests
assert on the list, nothing is logged.

Big ints and floats now lower correctly, so their old
`log.err` + `unreachable` stopgaps are gone.

## Minimum to unblock (the throwaway version)

If you want the file to compile today and have errors *fire loudly* without
building any infrastructure: stub the four methods to print to stderr and
return `error.AnalysisFail`. About 25 lines, no fields, no allocator
ownership beyond `gpa.free` of notes.

Shape:

```zig
fn failTok(astgen, token, comptime fmt, args) InnerError {
    std.debug.print("error at token {d}: " ++ fmt ++ "\n", .{token} ++ args);
    return error.AnalysisFail;
}

fn errNoteTok(astgen, token, comptime fmt, args) ![]const u8 {
    return std.fmt.allocPrint(astgen.gpa, fmt, args);
}

fn failTokNotes(astgen, token, comptime fmt, args, notes) InnerError {
    std.debug.print("error at token {d}: " ++ fmt ++ "\n", .{token} ++ args);
    for (notes) |n| {
        std.debug.print("  note: {s}\n", .{n});
        astgen.gpa.free(n);
    }
    return error.AnalysisFail;
}
```

(`failOff` mirrors `failTok` with the extra `offset` arg.)

What this *deliberately* does not do:
- Resolve token → line:col (you'd see `token 17`, not `example.duni:3:5`).
- Accumulate multiple errors (first hard fail aborts the whole pipeline).
- Survive into `Dir` (errors go to stderr, not into the returned IR).
- Free intermediate notes if one of several `try errNoteTok` calls OOMs
  inside a `&.{ … }` literal — those leak. Acceptable for an error path
  you're already aborting through.

This is the version that gets the file compiling. Treat it as scaffolding;
plan to replace it.

## TODO — to nail error reporting in AstGen

### Phase 1 — unblock
- [ ] Add the four stub methods above. File compiles end-to-end.
- [ ] Verify behaviour: write a test that parses a deliberately bad literal
      (`"1__2"`), expects `error.AnalysisFail` from `generate`, and
      asserts something showed up on stderr.

### Phase 2 — make errors structured
- [ ] Add `compile_errors: ArrayList(Item)` to `AstGen`. `Item`:
      ```zig
      struct {
          token: Ast.TokenIndex,
          offset: u32 = 0,
          msg: []const u8,     // owned by AstGen
          notes: []const Note, // owned by AstGen
      }
      ```
- [ ] Convert `failTok`/`failOff` to append to `compile_errors` instead of
      printing. They still return `error.AnalysisFail` for hard cases;
      introduce a `warn*` variant for recoverable cases (parallel to the
      parser's recoverable model).
- [ ] `errNoteTok` returns an in-arena `Note { token, offset, msg }`.
- [ ] `failTokNotes` moves notes into the `Item` instead of freeing them.

### Phase 3 — surface the errors past `generate`
- [ ] Add `errors: []const Item` to `Dir` (mirroring `Ast.errors`). Transfer
      ownership in `generate` via `toOwnedSlice`. Update `Dir.deinit` to
      free messages + notes + the slice.
- [ ] `generate`'s contract becomes: returns a `Dir` whose `errors` may be
      non-empty. `error.AnalysisFail` is still possible for catastrophic
      cases (probably OOM-style only); most errors should accumulate, not
      abort.

### Phase 4 — render against source
- [ ] Reuse / share with the parser's `tokenLocation` to map
      `(token, offset)` → `(line, col, line_slice)`.
- [ ] Write a `Dir.renderErrors(writer, tree, source)` (or shared
      `ErrorBundle.render`) that prints
      `<file>:<line>:<col>: error: <msg>` plus the offending source line
      and a caret, then each note.
- [ ] Hook the CLI to call it after `AstGen.generate`. Today there is no
      CLI — wire it in when `main.zig` returns.

### Phase 5 — share with the parser
- [ ] The parser already has its own `Ast.Error` array. AstGen's errors
      and Parse's errors are different shapes but conceptually identical.
      Unify into a single `ErrorBundle` module (the deleted `ErrorBundle.zig`
      hinted at this) and have both phases append to / render from one
      collection.
- [ ] Decide ordering: Parse errors first, AstGen errors only if Parse
      succeeded? Or always run AstGen on a best-effort AST? (Today Parse
      errors are checked before lowering — keep that until there's a
      reason not to.)

## Hard "do not build yet" list

- A full `ErrorBundle` with multi-file support, error groups, severity
  levels, machine-readable output. Adopt when there is a second consumer
  (LSP, batch tool) — until then, stderr + structured `Item` is plenty.
- Source-fix suggestions ("did you mean `0` instead of `-0`?"). Hard to
  do well; very easy to do badly. Defer until the language is more
  stable.
- Colorised output / TTY detection. After Phase 4.
