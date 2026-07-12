# Duni string literals

## The type system

Duni has **one** string type: `string`. Same philosophy as `number` — no
`str`/`String`/`&[u8]`/`StringBuilder` split, no fixed-vs-growable variants,
no encoding-tagged sub-types. A literal like `"hello"` is a value of `string`.

Everything beyond "there is one type called `string`" is still open — see the
TODOs below. The note is here to make those decisions visible so they get made
on purpose, not by accident through implementation choices.

## Pipeline status (as of today)

Strings are **unsupported at every layer**. There is no path from source to IR:

```
"hello"  --Scanner-->  (no string_literal token; `"` is not lexed)
         --Parser-->   (ParseRule for .string_literal is commented out)
         --AST-->      (.string_literal exists in Node.Tag but nothing emits it)
         --AstGen-->   (expr: .string_literal => unreachable)
         --Dir-->      (no string Inst.Tag; no string_bytes interner)
```

### What exists
- `Ast.Node.Tag.string_literal` is declared.
- `AstGen.expr` has a `.string_literal => unreachable` arm — purely defensive,
  never reached because Parse never produces the node.

### What is missing
- Scanner does not recognise `"`. There is no `string_literal` entry in
  `Token.Tag`.
- Parser has no `string` prefix rule (only the commented stub at
  `Parse.zig:96`).
- Parse does not emit `.string_literal` nodes; the AST tag is dead.
- `Dir.Inst.Tag` has no string variant. `Dir` has no `string_bytes` interner
  array (we removed `NullTerminatedString` when trimming Dir.zig).

## Open language design questions (decide these first)

These have to be answered before the implementation TODOs below are
well-defined. None are decided yet.

- [ ] **Encoding.** UTF-8 throughout (a text type)? Raw bytes (a `[]u8`-ish
      thing)? Both with a conversion at the boundary? Default expectation
      with "one type called `string`" is UTF-8, but write it down.
- [ ] **Mutability.** `string` values are immutable, full stop? Is there a
      separate buffer type for "build up a string" use cases, or is
      concatenation the answer (with the obvious O(n) cost)?
- [ ] **Quote forms.**
  - Single form `"..."` only?
  - Add `'...'` for char-like single-codepoint literals, or are those just
    one-codepoint strings?
  - Multiline form (`"""..."""`, backtick, leading-`\\\\` per Zig)?
  - Raw form (no escape processing)?
- [ ] **Escape sequences.** Pick a minimal set: `\n`, `\t`, `\r`, `\"`,
      `\\` at minimum. Then decide: `\x..` bytes? `\u{..}` codepoints?
      What is an error vs silently passed through?
- [ ] **Interpolation.** None for v0? `"hello, ${name}"`? Defer to
      `format()` style call? Interpolation has huge ripple effects on the
      Parser and IR — easier to say "no" now than rip it out later.
- [ ] **Length semantics.** What does `len("héllo")` return — bytes (6),
      codepoints (5), grapheme clusters (5)? Pick one; document it; don't
      try to expose all three through one function name.
- [ ] **Equality / ordering.** Bytewise on the UTF-8 representation
      (cheap, locale-free) or Unicode-aware? Cheap is almost always the
      right answer for a young language.
- [ ] **Empty / null.** Is `""` a normal value? (Yes — note it.) No null
      strings.

Pick a minimum here, write it into the language spec, then proceed.

## TODO — to nail string literals end-to-end

Roughly in dependency order. Each item is small once the design questions
above have answers.

### Scanner
- [ ] Add `string_literal` to `Token.Tag`.
- [ ] State-machine arm for `"`: consume until the closing `"`, handling
      escapes per the decided set. Unterminated literal → `invalid` token.
- [ ] Decide whether the scanner emits the **raw** lexeme (parser/AstGen
      decodes escapes) or the **decoded** lexeme (scanner copies into a
      side buffer). Raw is simpler; AstGen does the decode at lowering
      time — same pattern as `parseNumberLiteral`.
- [ ] Tests: empty `""`, simple `"abc"`, every escape from the chosen set,
      a literal containing a `"` via escape, an unterminated literal at
      EOF, a literal split by `\n` (decide: allowed in single-line form?).

### Parser
- [ ] Uncomment `ParseRule.init(Parse.string, null, .prec_none)` for
      `.string_literal` in `getRule`.
- [ ] Implement `fn string(p: *Parse) !Node.Index` — same shape as
      `number`: `addNode(.{ .tag = .string_literal, .main_token = advance(), .data = undefined })`.
- [ ] Test: a `"hello"` source parses to `root → string_literal`.

### Dir representation
- [ ] Add a `string` interner to `Dir`. Two coordinated pieces, same shape
      as Zig's `Zir`:
      - `string_bytes: []u8` — flat buffer of all decoded string content.
      - `NullTerminatedString = enum(u32) { empty = 0, _ }` — index into
        `string_bytes`, null-terminated so it can be reused as a `[:0]u8`.
      Reserve `string_bytes[0] = 0` so `empty` is a valid empty
      null-terminated slice.
- [ ] Add an `Inst.Tag.str` variant. Payload: `str: struct { start:
      NullTerminatedString, len: u32 }` (matches the variant we removed
      earlier — restore it when this lands).
- [ ] Update `Dir.deinit` to free `string_bytes`.

### AstGen
- [ ] Stop panicking in `expr` on `.string_literal`. Route to a
      `stringLiteral` helper.
- [ ] `stringLiteral`: read `tree.tokenSlice(main_token)`, strip the
      surrounding quotes, run an escape-decode pass into `string_bytes`,
      return `Inst{ .tag = .str, .data = .{ .str = { start, len } } }`.
- [ ] Escape decoder produces real compile errors (not `unreachable`) for
      bad escapes — `\q`, truncated `\x`, malformed `\u{...}`, etc., with
      token-level source locations.
- [ ] If interpolation is in scope, AstGen lowers
      `"a${expr}b"` into `concat(str("a"), to_string(expr), str("b"))`
      (or whatever primitive the runtime exposes) — not into a
      special `.interp` instruction. Keep `Dir` small.

### Sema (when it exists)
- [ ] Resolve every `str` instruction to a `string`-typed value.
- [ ] Concatenation operator (`+`? `++`? `..`?): pick *one*, applied to
      `string × string → string`. Document that mixing `string` and
      `number` is a type error (no implicit `to_string`).
- [ ] Comparison operators on `string`: define equality, decide whether
      `<` is meaningful (bytewise on UTF-8 is usable but surprising for
      non-ASCII).

### Runtime / Codegen (further out)
- [ ] Pick a representation: `{ ptr, len }` slice header? Length-prefixed?
      Reference-counted? For an immutable type the simplest answer is
      "compile-time literals live in a constant pool, runtime values are
      `{ptr, len}` heap allocations" — that defers GC questions.
- [ ] ABI for passing `string` across function calls.

### Tests
- [ ] One test per scanner-accepted form (basic, escaped, empty,
      multiline if supported).
- [ ] One test per scanner failure (unterminated, bad escape).
- [ ] One AstGen test that exercises a literal end-to-end and checks the
      bytes landed in `string_bytes` and the `Inst.str` payload is
      correct. Mirror the number-literal `test "output dir"` shape.
