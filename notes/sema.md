# Sema

## What it is

Sema (semantic analysis) is the pass between AstGen and codegen. It takes
untyped IR (DIR) and produces analyzed IR (AIR), interning every
comptime-known value in the `InternPool`.

Today Sema is **fold-only**: every value is comptime-known, every operation
folds, and the produced AIR is a single `ret` of an interned value. Runtime
values (and with them real AIR arithmetic instructions) don't exist yet.

## Pipeline

```
  AstGen        Sema         WatGen
    │            │              │
    ▼            ▼              ▼
  DIR  ──────► AIR  ────────► WAT
(untyped)   (ret of interned value)
```

## Structure

`analyze` walks the main body and dispatches on `Dir.Inst.Tag` — the switch
is **exhaustive with no `else`**, so adding a DIR tag forces a Sema decision
at compile time. Handlers:

```
.int      dirInt        intern .{ .u64 = value }, ty comptime_int
.int_big  dirIntBig     slice Dir.string_bytes, unaligned-copy limbs into
                        the arena, intern .big_int (always positive —
                        AstGen's invariant; sign arrives as .negate)
.float    dirFloat      intern .{ .f64 = value }, ty comptime_float
.negate   dirNegate     float operand → arith.floatNeg (bit sign-flip,
                        preserves -0.0 — `0 - x` would lose it);
                        else fold `0 - x` via the `zero` static
.add/.sub/.mul          dirArithmetic → analyzeArithmetic
.div      dirDiv        zero-divisor check, then arith.div
```

`Sema.arena` is scratch for analysis temporaries (big-int result limbs);
freed wholesale when `analyze` returns. Interning copies out of it, so
nothing interned points at arena memory.

`inst_map` maps each DIR instruction to the AIR ref (interned value) that
replaced it; `resolveInst`/`resolveValue` walk refs back to `Value`s.

## Arithmetic (`Sema/arith.zig`)

**Integers** canonicalize through `Value.toBigInt` — all three storages
(u64/i64/big_int) become `BigIntConst`, the op runs as big-int math, and the
result is interned as `.big_int` (the pool's encode funnel re-narrows small
results). `5 + 3` and `2^100 + 2^100` take the same path; negative and
beyond-u64 results are first-class.

**Floats** are plain f64 ops interning `comptime_float` results.

**Dispatch**: if either operand's key is `.float`, the op takes the float
path; `Value.toFloat` converts int operands (`.big_int` via `nearest_even`
rounding), so `comptime_int → comptime_float` coercion is implicit.

```
1 + 2        → comptime_int 3
1 + 2.5      → comptime_float 3.5     (int side coerced)
7 / 2        → comptime_int 3         (integer `/` is trunc)
7.5 / 2.5    → comptime_float 3.0     (float `/` is IEEE division)
```

> Note: an earlier draft of this note showed `1.0 + 2` as a type error.
> The implemented rule is coercion, Lua/Zig-style. Revisit deliberately if
> `number`'s final semantics disagree.

**Division by zero is a comptime error in both domains** — folding never
produces `inf`/`nan`. Integer zero is an O(1) index compare against the
`zero` static; float zero uses `Value.isZero`, where IEEE's `0.0 == -0.0`
conveniently catches both signs. `BigIntMutable.divTrunc` asserts a non-zero
divisor (no error return), so the check must happen at this layer — same
placement as Zig's `failWithDivideByZero` (analysis layer, where source
location lives; the arith value-helpers assume the precondition).

## Errors

`error.AnalysisFail` with no recorded message — error reporting is designed
(`notes/astgen_error_reporting.md`) but not built. Every `AnalysisFail` site
is a future call into it.

## Tests

`buildTestDir` hand-builds DIR (each stage's tests take the stage's input by
hand — no upstream chaining); `expectAnalyzed` asserts the result **by
index**: intern the expected key, compare indexes. Key-level `expectEqual`
is wrong twice over — big-int keys hold slices (pointer compare) and
`-0.0 == 0.0` under `==` — index identity is exact for every value kind
because dedup *is* equality.

## Declaration resolution — the `decls` table (2026-08-14)

Sema resolves declarations **eagerly, whole-program**: before analyzing the
module body, it iterates `module.decls` and resolves each into a `decls` map
(`Dir.NullTerminatedString` → `Air.Inst.Ref`). `.decl_val` is then a map
lookup on `str_tok.start`. AstGen dedups identifiers, so a decl's name and a
`decl_val`'s name are the *same* Dir string handle — the lookup is handle
equality, no re-interning. The lookup's `.?` rests on AstGen guaranteeing
declared identifiers (Zig's `lookupIdentifier` ends in `unreachable`).

This is deliberately **not** Zig's lazy model. Zig: `scanNamespace`
registers names into a persistent `Zcu.Namespace`, and each decl's value is
resolved on first reference (`ensureNavResolved`), memoized via the two-state
`Nav`. Duni collapses all of that: AstGen already produced `module.decls` (the
registration), and Sema resolves every decl up front. The map lives on
`Sema` (not a `Namespace`) because one module is analyzed in one pass; the
trigger to move it to a `Namespace`/`Nav` is multi-module (see
`notes/deferred.md`). Zig ref: `zirDeclVal` → `lookupIdentifier` →
`lookupInNamespace`; `analyzeNavVal` for the resolution.

## Resolving an extern's type — the inline body arms

`analyzeDeclaration` runs the declaration's `type_body` with `analyzeBody`
and reads the resulting func type off `inst_map.get(last)`, then interns
`Key.Extern`. The type body is a nested inline tree, so four DIR tags get
real Sema arms:

- **`break_inline`** (`dirBreakInline`): value = its operand. Duni's inline
  bodies are **linear, single-break, target = enclosing block**, so there's
  no `error.ComptimeBreak` unwinding — the value is computed at the break and
  stored in `inst_map`; the enclosing block reads its last instruction. Zig's
  `analyzeInlineBody`/`resolveInlineBody` exist only to demux that exception
  protocol; Duni needs neither.
- **`block_inline`** (`dirBlockInline`): run body, value = last inst. Today
  identical to `dirBlock` (fold-only, no runtime Air block), kept separate
  because they split when `block` grows a runtime path.
- **`param`** (`dirParam`): run the param's type sub-body → the param's
  **type**, into `inst_map`. Extern params are type-only, so a param maps to
  its type; when fn bodies arrive the param maps to its `Air.arg` value
  instead (the one line that changes).
- **`func`** (`dirFunc`): gather param types by **walking `param_block`** and
  reading each `.param`'s type from `inst_map` (not a `block.params`
  accumulator — the walk reuses the mandatory `inst_map` entries, avoids
  duplicate state, and `param_block` is load-bearing again for fn bodies),
  resolve `RetTy`, call `getFuncType`. Zig ref: `zirFunc`/`funcCommon`.
