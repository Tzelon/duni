# Duni — Type System Design Notes

*Working record, August 2026. The open questions from the first draft were
locked on 2026-08-26 (§9); the split between settled and open is marked
explicitly.*

---

## 0. Starting position

- Function **signatures are fully typed**; everything else is inferred.
- Sema is currently Zig-style forward evaluation — every type is concrete
  when inspected.
- Last implemented: function declarations and function calls.

**Why fully-typed signatures matter more than it looks.** They remove
let-generalization, the value restriction, and cross-module principality
concerns — the genuinely hard parts of Hindley–Milner. Inference is confined
to a function body with known input and output types, which is close to the
easy case. They also give every error a natural blame point.

---

## 1. Zig's type system is not a fit — decided

**What Zig gives:** types as comptime values, so generics, reflection, and
conditional compilation are one language rather than three. Free
introspection (`@typeInfo`, `inline for`). Layout in the type (`packed`,
`extern`, `u3`, pointer flavors). Typed inferred error sets.

**What it can't give:**

- **No expressible constraints.** `anytype` is an untyped hole. A function's
  requirements exist only in its body; you discover them by failing to
  compile a call site, with the error pointing inside the callee.
- **No modular checking.** A generic isn't checked until instantiated. You
  can ship a `pub fn` broken for every input and never know.
- **No interfaces.** `std` hand-rolls vtable structs (`Allocator`, `Writer`)
  with `@ptrCast`/`@alignCast` at the boundary.
- **No newtype identity.** `const UserId = u64` is just `u64`.

**The trade in one line:** Zig buys total control over representation and
pays by giving up abstraction over behavior. Right for a systems language;
wrong the moment a library boundary must enforce something.

---

## 2. Pattern matching over type overloading — decided

**Why, in order of weight:**

1. **No loops.** Recursion-only means every iteration is a base-case /
   recursive-case split. That split *is* pattern matching. Without it you
   write nested tag-checks, which read worse and compile worse — a match
   compiler builds a decision tree, chained ifs can't.
2. **Exhaustiveness.** A match is checked complete at its definition. Add a
   variant and every incomplete match errors immediately. A missing overload
   surfaces as "no matching function" at some distant call site, or never.
   Given the stated principle *push all errors to compile time*, decisive.
3. **Locality.** A match is one closed expression. Overloads are open and
   scattered across whatever is in scope.
4. **Export granularity.** Name/arity export (chosen partly to justify
   dropping currying) breaks if `add/2` names several functions.

Arity-based overloading is already available — `add/2` and `add/3` are just
different functions, Elixir-style. Type overloading only adds *same name,
same arity, different types*, and behaviors cover that better (§4).

### Recursion-only is a codegen requirement — decided

"No loops" makes iteration tail recursion, and WASM has no implicit TCO —
the native stack overflows without a story here. **Decision: require the
wasm `tail_call` feature** — emit `return_call` / `return_call_indirect`.
Full TCO including mutual recursion, no compiler transformation.

Consequences to carry:

- Sets a minimum engine requirement (standardized; shipped in V8,
  SpiderMonkey, wasmtime since ~2023).
- Toolchain: `wat2wasm` needs `--enable-tail-call` (or a recent wabt), and
  the test harness's Node must have the feature on. Add to the harness the
  moment the first `return_call` is emitted.

### Guards and exhaustiveness — decided

A guarded arm (`| n when n > 0`) contributes **nothing** to exhaustiveness;
the match must be complete via unguarded patterns alone (a final `| _` or
full constructor coverage). Standard Rust/OCaml/Elm rule. Guard coverage is
undecidable in general, and any "the checker can prove this guard" carve-out
becomes language surface that must be specified and kept stable — so none.

### Syntax

Signature once, clauses follow:

```duni
fn len(xs List(I64)) I64
  | []        -> 0
  | [_, ..t]  -> 1 + len(t)
```

Multi-parameter matching is positional:

```duni
fn zip(a List(T), b List(T)) List({T, T})
  | [], _                 -> []
  | _, []                 -> []
  | [x, ..xs], [y, ..ys]  -> [{x, y}, ..zip(xs, ys)]
```

Guards with `when`:

```duni
fn classify(n I64) Str
  | 0             -> "zero"
  | n when n > 0  -> "positive"
  | _             -> "negative"
```

Explicit body when there's work before the split:

```duni
fn area(s Shape) F64 {
  let scale = 2.0
  match s {
    | Circle(r)   -> 3.14 * r * r * scale
    | Rect(w, h)  -> w * h * scale
  }
}
```

Form 1 is sugar for Form 2 — same arm syntax in both.

**Key property:** `len` remains one exported symbol at `len/1`.

**Implementation synergy:** `=` is already a binding whose lhs is a pattern
(AstGen decides legal patterns). Clause heads, `match` arms, and `=` should
share one pattern mechanism, built once.

---

## 3. Structs have no methods; `x.f()` is pure sugar — decided

`x.f(y)` rewrites to `f(x, y)` **before name resolution**. There is no
method concept in the type system, no separate namespace, nothing new in
Sema.

**Why this matters:** it dissolves the UFCS lookup problem. Method-style
lookup needs an owning module for the receiver, and anonymous records
(`{name Str}`) have none. With pure desugaring, structural receivers stop
being special — the only remaining question is how an ordinary function name
resolves, which is now decided below.

Consequence: UFCS is a parser-level feature. It could be added or removed
late without disturbing the checker.

### Name resolution — decided

After desugaring, a bare call `f(x, y)` resolves against **one unified
candidate set**: lexically visible functions *plus* methods provided by
`where` constraints on the arguments' types. Exactly one match compiles.
**Two or more matches is a compile error naming both candidates — never a
silent pick.** No constraint-first shadowing (adding a constraint must not
silently change an existing call), no lexical-first (importing a helper
named `add` must not hijack protocol calls — the ADL failure mode). This
rule is what §3 and §5 need to compose.

### Function-typed fields — decided: none for now

Records hold data; functions appear only as parameters and top-level
declarations. So `x.f(y)` is *unconditionally* UFCS — there is no field-call
form to disambiguate. Revisit exactly when the `dyn` witness (§4) is
unparked; that is the one design element that needs a record of functions.

---

## 4. Behaviors (module-level) and protocols (type-level) — the Elixir split

Both concepts, as in Elixir. **Behaviors are parked**; protocols first.

**Division of labor:** protocol when a *value's type* determines the
implementation (`show`, `eq`, `encode`). Behavior when nothing in the data
determines it and the *build* chooses (storage backend, platform).

### Why protocols and not anonymous overloading

Overloading gives dispatch but no way to *state a requirement*:

```duni
fn sum(xs List(T)) T        // needs: T supports add — unstatable
```

There's no name for "the set of types with an `add`". That is the Zig
problem reintroduced one layer up. Naming the group fixes it and collapses
the overloading example into the protocol mechanism.

### Two changes from Elixir

- **Static, not dynamic.** Elixir dispatches at runtime on `__struct__`.
  Duni resolves at compile time and monomorphizes. Gain: `where T: P`
  constraints, which Elixir cannot express at all. Loss: "works on any term
  at runtime," which isn't wanted.
- **Consolidation stops being a problem.** Elixir's protocols are open —
  any module may `defimpl` anywhere — so dispatch tables can't exist until
  load time, hence the consolidation pass and its dev/prod gotchas.
  Whole-program compile plus an acyclic package graph means always
  consolidated.

### Behaviors, when unparked

Since modules are not values (parameterized packages were dropped), a
behavior is a **compile-time conformance check**: "this module exports these
functions at these types." Zero runtime representation; call sites are
direct, static, inlinable. Enough for the platform/host boundary, where the
build picks the implementing module.

If runtime choice is ever needed, add an **explicit witness** — `dyn Store`
as a struct of function pointers built by `Store.of(PgStore)`. Purely
additive; defer until a real case appears. (Unparking this also reopens
function-typed fields, §3.)

---

## 5. Protocol design — decided

| Decision | Choice | Reason |
|---|---|---|
| Orphan rule | Rust-style | Impl must live in the protocol's package or the type's package. Prevents a dependency change from altering dispatch. Fits the acyclic package graph. **Note: activates only once packages exist; until then everything is local and it is trivially satisfied.** |
| Impl heads | Nominal types only | Rows overlap (`{a}` vs `{a,b}`), and overlapping impls are where coherence gets genuinely hard. Structural constraints stay as row types in signatures; the mechanisms don't mix. |
| Associated types | Not now | Real expressive gain, real cost (type-level projections in the checker). Additive later. |
| Explicit vs implicit impl | **Explicit — decided** | See below. |
| `Self` only in return position (`fn default() T`, `fn decode(Buf) ?T`) | **Forbidden initially — decided** | Resolution would be return-type-directed — the impl picked by what the caller expects, not by any argument. That is where Rust's worst inference UX lives (`collect()` turbofish). Fully-typed signatures mean the expected type is usually known, so bidirectional checking makes this cleanly addable later; forbidding now costs decoders an explicit type argument at worst. |

### Why explicit impl, not Go-style implicit

Go's implicit satisfaction is safe only because of a second rule: **methods
must be defined in the same package as the type.** So there is exactly one
`String()` for `Account`, ever — coherence is structurally impossible to
violate rather than enforced.

The cost Go pays: **no retrofit.** If package A defines `Stringer` and
package B defines `Account` whose author never wrote `String()`, nobody can
fix it. Workaround is a wrapper type, losing identity.

Rust's orphan rule is *more permissive* — it allows an impl in the
protocol's package too, so a foreign type can satisfy your own protocol.
But an impl for a foreign type must live somewhere and be attributable.
**Rust-style orphan rule implies explicit impl blocks; they are not
independent choices.**

Duni-specific blocker anyway: structs have no methods (§3), so implicit
satisfaction would have to mean "is there a function `show(Account) Str`
visible somewhere" — lexical and import-sensitive. Adding an import could
make a type start satisfying a protocol.

Secondary: implicit satisfaction is accident-prone. Two protocols each
declaring `fn size(T) I64` with different meanings — a type satisfies both
without anyone intending it.

### Examples

```duni
protocol Add for T {
  fn add(T, T) T
}

impl Add for I64 { fn add(a I64, b I64) I64 { a + b } }
impl Add for Str { fn add(a Str, b Str) Str { concat(a, b) } }
```

Return type tracks the argument — what a union parameter could not express.

Using a constraint:

```duni
fn sum(xs List(T), zero T) T where T: Add
  | []       -> zero
  | [x, ..t] -> x.add(sum(t, zero))
```

Inside the body, `x.add(...)` resolves through the unified candidate set of
§3 — the `where T: Add` method is a candidate, lexical functions are
candidates, and two matches is an error. `sum([1,2,3], 0)` and
`sum(["a","b"], "")` both work; monomorphization emits two copies with calls
already resolved.

Conditional impl — the one that makes protocols compose:

```duni
impl Show for List(T) where T: Show {
  fn show(xs List(T)) Str
    | []       -> ""
    | [x]      -> x.show()
    | [x, ..t] -> x.show() + ", " + t.show()
}
```

`List(List(I64))` resolves by discharging recursively: `Show for
List(List(I64))` → head `List(T)` with `T = List(I64)` → `Show for
List(I64)` → `Show for I64` → found. Terminates because each step is
structurally smaller.

### Opacity — decided: separate `opaque type` keyword

```duni
// package: accounts
opaque type Account = { id Str, balance I64 }

impl Show for Account {
  fn show(a Account) Str { "Account(" + a.id + ")" }   // fields visible here
}
```

Outside the package nobody sees `id` or `balance`, but `acct.show()` works.
A row constraint `{id Str}` could never reach inside. Opacity and protocols
compose; opacity and rows don't.

Decided as a **distinct declaration form**, not "nominal type with
unexported constructors" (the road Roc took). Obligation that comes with the
choice: its interaction with visibility must be specified explicitly — a
non-owning package sees the *name* only; no fields, no constructor, no
literal syntax. That spec is owed before implementation.

Retrofit — what the Rust orphan rule buys over Go:

```duni
// package: myapp
impl Show for Account { ... }        // REJECTED — both foreign

protocol Pretty for T { fn pretty(T) Str }
impl Pretty for Account { ... }      // OK — Pretty is local
```

Rows and protocols side by side, different jobs:

```duni
fn label(u {name Str, ..r}) Str    // structural: any record with a name
fn render(x T) Str where T: Show    // nominal: any type implementing Show
```

`impl Show for {name Str}` is rejected — nominal heads only.

---

## 6. Rows — decided

A **row** is the field-set part of a record type. A **row variable** is a
hole in that field-set.

```duni
fn label(x {name Str, ..rest}) Str
```

Naming the row is what lets unknown fields flow *through* a function:

```duni
fn rename(p {name Str, ..r}, n Str) {name Str, ..r}
```

With only an "open record" flag, the extras would be lost at the boundary.

**Closed by default — decided.** `{name Str}` means exactly one field; extra
fields are a type error. Openness is opt-in and visible: `{name Str, ..r}`.
Errors stay sharp (a typo'd field name can't hide in an open tail) and
inference stays principal without defaulting heuristics.

**Unification.** Given `{a: I64, ..r1}` against `{b: Str, ..r2}`: common
fields unify pointwise; left-only fields go into the right's tail
(`r2 := (a: I64, ..r3)`); right-only into the left's (`r1 := (b: Str,
..r3)`); `r3` fresh and shared. Both rows grow toward a common unknown tail.

**Canonical field ordering** (sort by name) makes step 1 a merge-walk instead
of a nested search, and makes interning work.

**Presence-required spread — decided.** `{...p, name: n}` requires `name`
to already be in `p`'s row. Spread overwrites, never extends. Consequence:
the result type equals the input type, and row subtraction (`r \ name`) and
"lacks" constraints are never needed — the part of extensible records that
gets ugly in Haskell. Extension, if ever wanted, is a separate future
feature that must bring the lacks-constraint machinery with it.

---

## 7. Comptime and macros

### Decided

- **No comptime in signatures.** Signature types must be readable without
  evaluation. `fn f(x Vec3)` where `Vec3` was comptime-made at its
  declaration is fine; `fn f(x @TypeOf(gen()))` is not. This protects the
  property the whole design leans on.
- **Nim-style macros.**
- **A comptime-constructed type may not depend on a type parameter**
  (constants and already-ground types only) — confirmed, see below.

### Nim's model

Macros are ordinary procs running on the compiler VM, with the stage chosen
by **parameter mode**:

```nim
macro dump(x: untyped) = ...   # raw AST, pre-semantic-analysis
macro derive(T: typed) = ...   # post-sem, types visible
```

So it's one interpreter with two modes, not two interpreters at two IR
levels. Meaningful simplification.

### Comptime type construction — decided rule

**Allowed at declaration level:**

```duni
type Vec3 = comptime make_vector(3, F64)
fn scale(v Vec3, k F64) Vec3        // ordinary signature
```

Evaluated during declaration processing, before any body is inferred. By
inference time `Vec3` is ground and interned.

**The line — generating code vs constructing types:**

```duni
// generating CODE from a type parameter — fine
fn struct_eq(a T, b T) Bool where T: Struct {
  inline for f in fields(T) { ... }
}

// constructing a TYPE from a type parameter — rejected
fn f(x T) ... where T: Struct {
  const Pairs = comptime map_fields(T, ...)   // T not ground yet
}
```

Inference must reason about `Pairs`, whose value depends on `T`, which is
ground only at monomorphization — after inference. Circular.

**The rule:** a comptime-constructed type may not depend on a type
parameter. Constants and already-ground types only. Reading note: the
`wasm_export` example below stays legal *only because* its return type
`WasmFn` is fixed while the generated code varies per instantiation — the
line is types vs code.

### The concession to accept deliberately

Code inside a comptime/macro region in a generic function is **not checked
generically** — it's checked per instantiation, exactly like Zig. The
difference is that the region is *syntactically delimited*: everything
outside is checked once, and you can see which regions carry deferred
errors. Zig gives no such boundary.

### What comptime buys: derive without derive machinery

| | Mechanism | Stage | Sees types? | Cost |
|---|---|---|---|---|
| Rust | proc macro (separate crate, `syn`/`quote`) | tokens | No | second language |
| Go | `reflect` | runtime | Yes | allocation, no inlining, panics |
| Elixir | `quote`/`unquote` macros | AST | No — names only | no type fidelity |
| Duni | comptime / typed macro | post-inference | Yes | error blame |

Structural equality:

```duni
fn struct_eq(a T, b T) Bool where T: Struct {
  inline for f in fields(T) {
    if !f.value(a).eq(f.value(b)) { return false }
  }
  true
}

impl Eq for Account = struct_eq
```

`f.value(a).eq(...)` resolves through `Eq` for whatever the field's type is,
recursively. Add a field whose type has no `Eq` impl and the error names
that field, at compile time.

Codec — where field *types* matter, not just names:

```duni
fn struct_encode(x T, b Buf) Buf where T: Struct {
  inline for f in fields(T) {
    b = f.value(x).encode(b)
  }
  b
}

impl Encode for Account = struct_encode
```

Emitted code is a straight-line sequence of `write_i64` / `write_str` with
offsets already known. Elixir's `@derive` cannot do this — it has field
names but no field types.

Platform/host glue — Duni-specific:

```duni
fn wasm_export(f (A) -> B) WasmFn where A: Struct, B: Struct {
  comptime {
    // A's fields → flat i32/i64/f64 params
    // B → return slot + linear-memory layout
    // refcount ops at the boundary, derived from field types
  }
}
```

Field types tell you which fields are heap-allocated, so the correct
increment/decrement can be emitted rather than tracked by hand. Connects the
RC decision directly to the type system.

### Why `impl Eq for Account = struct_eq` and not a blanket impl

```duni
impl Eq for T where T: Struct { ... }   // NO
```

This overlaps any hand-written `impl Eq for Account`. Resolving overlap
requires specialization — unstable in Rust since 2015, still unsound in
general. Making derivation an explicitly-invoked *generator* keeps exactly
one impl per (protocol, type) and preserves coherence.

### Three mechanical requirements

- **Impl heads name the type, not the expression.** `impl Show for Vec3` yes;
  `impl Show for make_vector(3, F64)` no. Otherwise matching a type against
  impl heads requires evaluation and resolution stops being decidable.
- **Structural identity via InternPool.** `make_vector(3, F64)` from two
  places must produce the same type. Key the intern on constructor + args.
- **An evaluation budget.** Zig's branch-quota equivalent, before it's needed.

### Naming

Use `inline for` (Zig's name) for unrolling over a compile-time-known
sequence, distinct from `comptime` blocks. Mechanically it's loop unrolling
over already-typed IR — far less machinery than macro expansion, no AST
synthesis, no hygiene concerns.

### Nim's known weak spots — avoid deliberately

- Type queries are inconsistent (`getType` / `getTypeImpl` / `getTypeInst`);
  pick **one** type-query API.
- Macros aren't hygienic; templates mostly are. Choose **hygiene by default**
  with explicit opt-out.
- Errors inside generated code point at generated positions. Build a **macro
  expansion stack** into every diagnostic — this is the Zig failure mode and
  the reason for leaving Zig in the first place. The decl-relative
  `LazySrcLoc` plumbing is the right substrate, but this is a feature to
  build, not a freebie.
- Do **not** take Nim's overload resolution — lexical, ADL-adjacent, inherits
  C++'s problems.

---

## 8. What this costs in the compiler

### Transfers from the current Zig-style implementation

- **InternPool** — structural dedup of ground types, exactly right for rows.
- **Instantiation-with-cache** — keyed on comptime args, same shape as
  monomorphizing per call site.
- **Src-loc plumbing** — decl-relative offsets already exist. (The
  Diagnostics collector's node-location model — see
  `notes/future/diagnostic.md` — is the substrate errors build on.)
- **Comptime evaluation** — still wanted, just relocated in the pipeline.

### Must be built

| Piece | Effort | Notes |
|---|---|---|
| Type variables + union-find | Moderate | Mutable store, **separate** from InternPool — unresolved vars can't be interned |
| Unification + occurs check | Moderate | Standard |
| Row unification | Small once unify exists | Needs canonical field ordering |
| Bidirectional check/infer | **The bulk** | New pass, different shape from forward evaluation |
| Impl index + resolution | Small | Keyed `(protocol, head type)`; recursive `where` discharge. Overlap checking is trivial given nominal-only heads |
| Protocol conformance check | Small | Substitute `Self`, unify each signature. Needs no unification for ground impls — can land under today's forward-evaluation Sema, before the checker |
| Error blame | Underestimated | Unification reports at the unify site, not where the human erred. Record a *provenance trail* on every tvar binding from day one — cheap now, miserable to retrofit |
| `return_call` emission | Small | WatGen; gated on the wasm `tail_call` feature (§2). Harness needs `wat2wasm --enable-tail-call` and a Node with the feature |

Roughly a third of the machinery transfers; none of the mental model does.

### Phase ordering

```
parse
resolve decls + evaluate comptime type constructors   ← named types now ground
resolve signatures
infer / check bodies                                   ← generic, once
monomorphize + expand comptime & macro regions         ← per instantiation
RC insertion                                           ← needs concrete layout
codegen
```

**Constraint:** RC insertion must come after monomorphization, since refcount
placement depends on knowing which fields in the concrete layout are
heap-managed.

### Timing — decided 2026-08-26

**Don't split Sema yet; install the seams now, split at the trigger.**
Forward evaluation carries the language through the end-to-end WASM
milestone — booleans, `if`/`else`, runtime blocks, `match` on concrete
types, tail calls, string ops. None of those produce a type that can't be
resolved by looking at it. A solver written before a single row variable
exists is designed against imagined requirements.

Two head starts already exist: `Sema.analyze` registers all decls before
analyzing any body (a proto two-sweep), and `Result` emits one Air per
function — the exact shape monomorphization generalizes (one Air per
*instantiation*).

**The seams — a small dedicated arc, before the checker has a consumer:**

1. **Type handle distinguishes interned from tvar.** Not a Zig
   `union(enum)` — that breaks the 8-byte `Air.Inst.Data` budget (`arg` is
   already `ty + u32`). Steal the MSB of the u32, exactly the idiom
   `Air.Inst.Ref` already uses to split interned values from instruction
   indexes. The `tvar` arm is never constructed yet; the point is that
   every site handling a type already branches on it.

2. **Argument checking goes through `unify(expected, actual)`** — even if the
   body is `return expected == actual` for now. That function is where the
   checker eventually lives.

3. **Split signature resolution from body checking** — two sweeps per package.
   Needed anyway for mutual recursion, and it's the structure the
   bidirectional checker wants.

(Seam 4, from the diagnostics arc: when tvars arrive, bind them with a
provenance record from the first commit — see the error-blame row above.)

**Status 2026-08-26: seams 1–3 installed.** `Type` is the MSB-tagged handle
(`TypeVar.Index` is a placeholder with no store or producer); `Sema.unify`
exists and answers coerce's runtime-path compatibility test and `dirRet`'s
void check (its doc comment lists the sites deliberately not routed — the
module boundary has no declared result type, so there is nothing to unify
against there); the two sweeps are named `resolveDeclarations` /
`analyzeFnBodies`, with the no-body-before-all-decls contract pinned by
`test/cases/wat/forward_call.duni`. Seam 4 (tvar provenance) waits for the
first tvar producer.

**Trigger to actually split — binding:** the first feature whose types are
not ground during body analysis: generic containers (`List(T)`), row
variables, or `where`-constrained params. Not before, and not later — the
feature that fires the trigger waits for the split rather than being
hacked onto forward evaluation.

---

## 9. Locked 2026-08-26

The first draft's open questions, resolved:

| Question | Decision |
|---|---|
| Bare-name resolution after UFCS desugar | **Unified candidate set** (lexical + constraint methods); two matches is a compile error naming both — never a silent pick (§3) |
| Guards vs exhaustiveness | **Guarded arms never count** toward coverage (§2) |
| Rows: open or closed by default | **Closed**; openness is explicit `..r` (§6) |
| Rows: spread extends or overwrites | **Presence-required** — overwrite only (§6) |
| Explicit impl blocks | **Confirmed**, with the Rust-style orphan rule (§5) |
| `Self` in return position only | **Forbidden initially**; revisit with bidirectional checking (§5) |
| Function-typed record fields | **None for now** — `x.f(y)` is unconditionally UFCS; the `(u.f)(y)` question is dissolved, not answered. Revisit iff the `dyn` witness is unparked (§3, §4) |
| Opacity | **Separate `opaque type` keyword**; visibility semantics owed before implementation (§5) |
| Comptime type construction from a type parameter | **Forbidden** — confirmed (§7) |
| Tail calls on WASM | **Require the wasm `tail_call` feature** (§2) |
| Pipeline split | **Seams now, split at trigger** — forward evaluation until the first non-ground type (`List(T)`, rows, or `where` params); that feature waits for the split (§8) |

Still genuinely open:

| Question | Status |
|---|---|
| Whether the macro system's remaining use cases survive contact with comptime | Open — if the only wanted cases are derive-style, comptime covers them |
| Associated types | Deferred by decision (§5), not designed |
| Behaviors | Parked (§4) |

---

## 10. Reference: what the neighbours do

- **Roc** removed abilities entirely, replacing them with Go-style static
  dispatch; also removed lambda set inference, module params, and tuple
  extensibility, and replaced opaque type wrappers with nominal tag unions.
  Static dispatch is *name resolution*, not a constraint system — you cannot
  state a requirement in a signature. Same failure mode as `anytype`, better
  error locations. **Not copied here.**
- **Elixir** has both behaviors and protocols, which is the split adopted, but
  both are dynamic and unchecked relative to what's proposed here.
- **Go** gets away with implicit satisfaction only via the same-package method
  rule; the price is no retrofit.
- **Rust** is the closest model for protocols. Its residual sharp edges:
  inherent methods shadow trait methods (so adding one is technically
  breaking), and `Deref` can route calls unexpectedly. Neither applies to
  Duni, which has no inherent methods and no deref coercion.
