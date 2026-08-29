# Sema

## What it is

Sema (semantic analysis) is the pass between AstGen and codegen. It takes
untyped IR (DIR) and produces analyzed IR (AIR), interning every
comptime-known value in the `InternPool`.

Today Sema is **fold-only for values**: every arithmetic operand must be
comptime-known, and every arithmetic operation folds to an interned value.
A runtime operand reaches `unreachable` in `analyzeArithmetic`
(`src/Sema.zig:321`), which is why `test/cases/run/runtime_arithmetic.duni`
panics rather than failing.

AIR is not empty, though: calls survive analysis. `Air.Inst.Tag` has two
variants, `ret` and `call`, so a program that calls a host import produces a
real instruction stream, while its arguments are folded constants.

## Pipeline

```
  AstGen        Sema         WatGen
    │            │              │
    ▼            ▼              ▼
  DIR  ──────► AIR  ────────► WAT
(untyped)    (typed: ret, call)
```

## Structure

`analyze` walks the main body and dispatches on `Dir.Inst.Tag` — the switch
is **exhaustive with no `else`**, so adding a DIR tag forces a Sema decision
at compile time. Handlers:

```
.int          dirInt         intern .{ .u64 = value }, ty comptime_int
.int_big      dirIntBig      slice Dir.string_bytes, unaligned-copy limbs into
                             the arena, intern .big_int (always positive —
                             AstGen's invariant; sign arrives as .negate)
.float        dirFloat       intern .{ .f64 = value }, ty comptime_float
.str          dirStr         intern the string handle
.negate       dirNegate      float operand → arith.floatNeg (bit sign-flip,
                             preserves -0.0 — `0 - x` would lose it);
                             else fold `0 - x` via the `zero` static
.add .sub     dirArithmetic  → analyzeArithmetic
.mul .div                    (`.div` carries its zero-divisor check there)
.block        dirBlock
.break        dirBreak
.block_inline dirBlockInline
.break_inline dirBreakInline
.decl_val     dirDeclVal     lookup in the eagerly-resolved `decls` map
.func         dirFunc
.param        dirParam
.call         dirCall        → analyzeCall
.extended     unreachable    the module instruction is never inside a body
.declaration  unreachable    declarations live in the module's decl list
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
7 / 2        → comptime_float 3.5     (`/` is always IEEE division)
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
([DP-0001](../proposals/0001-diagnostics.md)) but not built. Every
`AnalysisFail` site is a future call into it, and several paths that should
fail are `unreachable` instead.

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
trigger to move it to a `Namespace`/`Nav` is multi-module — a deliberately
deferred decision. Zig ref: `zirDeclVal` → `lookupIdentifier` →
`lookupInNamespace`; `analyzeNavVal` for the resolution.

## Resolving an extern's type — the inline body arms

`analyzeDeclaration` runs the declaration's `type_body` with `analyzeBody`
and reads the resulting func type off `inst_map.get(last)`, then interns
`Key.Extern`. The type body is a nested inline tree, so four DIR tags get
real Sema arms:

- **`break_inline`** (`dirBreakInline`): value = its operand. Duni's inline
  bodies are **linear, single-break, target = enclosing block**, so there's
  no `error.ComptimeBreak` unwinding — a body's result is read straight off
  the terminating break's `operand` (see `resolveInlineBody` below), never
  merged. Zig's `analyzeInlineBody`/`resolveInlineBody` exist mostly to demux
  that exception protocol; Duni's `resolveInlineBody` is the trivial linear
  case.
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

## `resolveInlineBody` and the control-flow seam

`resolveInlineBody(body)` runs the body, then returns its result by decoding
the **terminating `break_inline`'s `operand`** — not `inst_map.get(body[last])`.
The value flows through the break's operand (the real dataflow), matching
Zig's model where `break_inline` is a *terminator*, not a value-producing
instruction. The break is last by construction — every AstGen inline body ends
in `addBreak(.break_inline, …)` — asserted on the tag. Shared by every
inline-body site: `dirParam`, `analyzeDeclaration`, `dirBlockInline`,
`analyzeArg`. (Consequence: `dirBreakInline`'s `inst_map` write is now dead —
nothing reads a break by index — so `.break_inline` need not stay a
value-producing dispatch arm once this lands.)

Correct only because today's bodies are **linear and single-break**. Each
control-flow feature breaks a different assumption, and the fix is Zig
machinery added *around* the same operand read, not a rewrite:

- **conditional `break` / early `return`** — the break is no longer last (it
  sits inside an `if`). Needs `error.ComptimeBreak` + `comptime_break_inst`
  unwinding (`analyzeBodyInner`) so a nested break reaches its target.
- **multiple exits** — a block caught by several breaks → the result is a
  **merge** (`Block.Merges`): the taken value at comptime, a runtime
  `block`/`br` otherwise. Replaces "result = last inst's operand".
- **labeled `break :outer`** — target ≠ enclosing block; the break's stored
  `block_inst` target is compared and propagated outward.
- **loops** (`continue`) — runtime control-flow Air: `br`/`cond_br`/`loop`.

`resolveInlineBody` **survives** all of this as the linear-inline fast path —
param/arg/decl-type bodies are genuinely loop-free expressions, exactly like
Zig's kept `resolveInlineBody`. The merge/unwind path is added *alongside* for
runtime block/loop bodies. Lands with the loops arc; not pre-built.
