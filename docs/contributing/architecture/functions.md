# Functions

How function declarations and calls are represented and lowered. Functions are
the feature that ends the fold-only era — parameters are the first runtime
values, so the arc touches every stage.

## AST shape

- `fn_decl` — `node_and_node` {proto, body block}; main_token = `fn`.
- `fn_proto` — main_token = `fn`; the fn name is the token at
  `main_token + 1`, not a node. data = `extra_and_opt_node`
  {ExtraIndex → `Node.FnProto` {params_start, params_end, rparen},
  optional return-type node}. The params span holds the param *type
  expression* nodes only; a param's name is the token before its type's
  first token. The `params`/`param`/`ret` wrappers are gone.
- `extern fn` — a bare `fn_proto` decl (no body, no `extern_fn` node);
  the `extern` keyword is the token before the proto's `fn` (Zig's model).
- `call` — `node_and_extra` {callee node, ExtraIndex → `Node.Call`
  {args_start, args_end, rparen}}; main_token = `(`. Identifier callees
  only for now, checked in the parser (AstGen has no error reporting yet).
- The closing `)`/`}` are stored in the extra structs (`rparen`/`rbrace`,
  also `Node.Block`) so `lastToken` returns stored tokens or child answers,
  never derived offsets or scans — required for correct spans under error
  recovery (`{ + }` skips tokens no derivation can see).
- **The parser takes no InternPool** (`Ast.parse(gpa, source)`); names
  live in tokens and are interned by AstGen (`identAsString`). The
  macro/quote rationale in "Dynamic ops" moves to a later lowering stage
  rather than being the AST's shape.

## Lowering

`extern fn` and parameters lower in AstGen following Zig's `fnDecl` /
`fnProtoExpr` / `setDeclaration` / `addFunc` / `addParam` directly:

- `rootModuleDecl` scans the container (`scanContainer` → `WipDecls` over a
  reusable `Scratch` region on `astgen.scratch`), lowers each
  `fn_proto`/`fn_decl` via `fnDecl`, then the implicit main body.
- **Extern = a body-less `fn_proto` → a function *type* only** (Zig's
  split): `fnDecl` emits a `declaration` envelope, and `fnProtoExpr`
  lowers each param (`addParam`, the param's type in its own
  `break_inline`-terminated sub-body) and the return type, then `addFunc`
  with `body_gd = null`. A non-extern body is still `unreachable`.
- **New DIR, mirroring ZIR:** `declaration` (envelope carrying optional
  type/value bodies), `func` (a *type* when `body_len == 0`), `param`
  (name + a type sub-body), and `block_inline`/`break_inline` (inline
  bodies exited by breaking to their block). Plus a `void_type` sentinel
  `Ref`/`Index` for "no return", a `pl_tok` data variant, and
  `number` → `.f64_type` in `primitive_instrs`.

`extern fn print(x number) number` lowers as: a `declaration` whose
type-body is one `block_inline` holding the `param`, the `func`, and the
`break_inline` that yields the func. 21/21 AstGen tests green.

**Call lowering done (2026-08-08):** `.call` in `expr` → `callExpr`. The
callee is lowered via `expr` (identifier → namespace hit → `decl_val` by
name); each arg is lowered into its own sub-block terminated by
`break_inline`, the arg bodies are staged through `astgen.scratch`, and a
`call` Dir instruction is emitted with `Call{callee, args_len}` plus the
trailing arg bodies. `extern fn print(x number) number` + `print(42)`
lowers to the expected DIR (test "call").

**Not yet done, blocking end-to-end:** (1) `Sema.zig:86` is non-exhaustive
over the new tags (`block_inline`/`break_inline`/`declaration`/`param`/
`func`/`call`), so full `zig build test` doesn't build (AstGen tests pass
in isolation). (2) The `Declaration` payload has no flags word yet, so a
decl's name/linkage/bodies aren't decodable (print's `writeDeclaration`
is a stub); Zig's `Flags` (kind, linkage, has-name/-lib_name/-type_body/
-value_body) is the missing piece Sema needs to tell extern from normal.

## Syntax

```duni
fn add(x number, y number) number {
  x + y
}
```

- Params are Go-style: `name type`, no colon. No ambiguity: params are parsed
  by a dedicated `parseParamDecl` inside the parens, never through the Pratt
  expression path, so "identifier then typeExpr" is positional.
- `typeExpr` is a bare identifier today (`number`, `string`).
- Trailing comma in the param list is allowed (Zig does the same; call
  arguments will match).

## Historical — the form-based AST design

Everything in this section describes a design that was implemented and then
reversed. It is kept for its reasoning, not as a description of the compiler.
See [0006](../decisions/historical/0006-closed-node-tags-over-open-forms.md).

<details>
<summary>The form-based design and why it lost</summary>

## AST shape — mimic Elixir's `def`

> **Superseded — see the update at the top.** Kept as the record of the
> form-based design and its reasoning.

Elixir:

```elixir
{:def, [line: 1],
 [
   {:add, [line: 1], [{:x, [line: 1], nil}, {:y, [line: 1], nil}]},
   [do: {:+, [line: 2], [{:x, [line: 2], nil}, {:y, [line: 2], nil}]}]
 ]}
```

Duni, same idea in the DoD representation:

```
form      op="fn"     main_token=`fn`      children: [proto, body]
├─ form  op="add"    main_token=`add`      children: [params, ret]
│   ├─ form  op="params"  main_token=`(`       children: [param, param]
│   │   ├─ form  op="param"  main_token=`x`    children: [symbol x, symbol number]
│   │   └─ form  op="param"  main_token=`y`    children: [symbol y, symbol number]
│   └─ form  op="ret"     main_token=`number`  children: [symbol number]
└─ block { form op="+" [symbol x, symbol y] }
```

- There is only one form representation: `form{op: NullTerminatedString,
  args: ExtraIndex → SubRange}` — every form's children live in `extra_data`
  as a span (`Ast/Node.zig`). No fixed/dynamic split; `fn` is a form with a
  2-element span, a proto is a form with params+1.
- The proto's op is **the function name itself**, exactly Elixir's
  `{:add, meta, [...]}`. Nothing dispatches on it; AstGen knows children[0]
  of a `"fn"` form is the proto positionally, then reads the name from the
  proto's op. This is the first form whose op comes from an identifier token
  rather than an operator token — and unlike the operator ops, which are
  static `NullTerminatedString` entries, an identifier op is a dynamic
  string interned at parse time. See "Dynamic ops" below for the decision.
- **Every proto child announces what it is — no positional decode rule.**
  The proto has exactly two children: a `form{op="params"}` wrapper
  (main_token at the `(`) holding the `form{op="param"}` pairs, and
  `form{op="ret", [typeExpr]}` with main_token at the type token. Consumers
  and macros match on op, never on child index. The wrappers cost a couple
  of nodes per function and were chosen over positional rules ("last child
  is the ret type") because the proto's tail is about to get crowded:
  literal patterns in param position (multi-clause), guards (`when`), and a
  possibly-optional ret type under inference would each have forced a new
  positional convention. With wrappers, each future head element just gets
  its own op. The params wrapper also keeps `parseParams` a self-contained
  scratch-region owner in the parser — no cross-function appending contract.
  If the return type is missing, the parser warns (recoverable) and emits a
  one-child proto; AstGen detects the absent `ret` form structurally.
- A param is a `form` with synthetic op `"param"`, children
  `[name symbol, type symbol]`, main_token at the name. There is no colon
  token to serve as a natural operator, and flattening pairs into the proto
  would hand macros a positional soup.
- The body is the existing block node — nothing new.

## Why not Zig's shape

> **Superseded — the reversal adopted Zig's shape.** Duni now discards
> names to tokens exactly as described below (one `fn_proto` variant with a
> `FnProto` extra struct instead of Zig's four packed variants).

Zig's fn AST is shaped by two forces Duni rejects:

- **Four proto variants** (`fn_proto_simple/_multi/_one/fn_proto`,
  `Ast.zig:3520-3577`) exist purely to pack small protos into the 8-byte
  `Node.Data` and spill big ones to `extra_data`. That multiplicity is the
  cost of closed tags; the open-form design pays a few more nodes instead.
- **Zig does not store the fn name or param names in the AST at all.** The
  parser consumes and discards the name token (`Parse.zig:687`); later stages
  recover it from the token stream at `main_token + 1`, and param names come
  from a token-scanning iterator. Saves bytes, but the proto cannot be
  reconstructed from nodes alone. A macro-generatable `fn` requires the full
  shape in the AST, so Duni stores names as symbols and the fn name as the
  proto's op — consciously paying nodes for homoiconicity.

Closest thing Zig has to an open-operator form: `builtin_call` — the operator (`@foo`)
is not a tag, it's recovered from the main token's text, and args live in
`extra_data`. Zig allows that open-operator shape only for builtins; Duni
makes it the universal rule.

## Dynamic ops — the InternPool is threaded into Parse

> **Superseded — reversed with the form design.** The parser no longer
> touches the InternPool; AstGen interns names from tokens. The quote/macro
> argument below is real but now lands at the macro-expansion layer
> (generated AST without tokens), not at parse time.

**Decision: `Ast.parse` takes a `*InternPool`, and the parser interns
identifier-derived ops (proto heads, call heads) at first sight.** The
alternative — static marker ops (`.call`, `.proto`) with names left in
tokens, Zig's model — was rejected after walking the macro lifecycle:

- **Parse:** `unless(cond) { ... }` is `form{op="unless", [...]}`. The
  parser cannot tell a macro call from a function call and never needs to —
  no new tokens, no context flags. The parser stays frozen while the
  language grows; interning at parse time is what makes this mechanical.
- **AstGen dispatch:** three tiers, all handle (u32) comparisons — static
  ops lower directly, declaration forms, else namespace lookup on the op
  handle → macro (expand) / function (call) / undeclared (error). Under
  markers, every consumer instead pays token → source slice → intern →
  lookup; interning is delayed, not avoided.
- **quote is the killer:** macro expansion produces AST that came from no
  source — *there are no tokens for generated names*. Token-resident names
  cannot represent macro output; the marker model would need a second,
  handle-backed identifier representation bolted on (i.e., this mechanism,
  added late, with both paths maintained forever). Elixir interns atoms at
  parse time for exactly this reason and keeps `meta` optional so generated
  AST is legal. Zig keeps names in tokens because Zig has no AST-value
  macros.
- **One universe of names:** macro bodies run in Sema's comptime engine and
  quoted AST flows Parse → AstGen → Sema → back. With the single InternPool
  threaded from the start, a handle interned by the parser is directly
  comparable everywhere in that loop.

Accepted costs: `Ast.parse` signature change (main and every parse test
constructs/threads a pool), and the Ast is only interpretable next to its
pool — already true of Dir and Air.


</details>

## Multi-clause functions — not built

> Design intent, not current behavior. Nothing below exists; when this is
> taken up it should become a proposal.

Duni will have Elixir-style multi-clause functions:

```duni
fn fib(0) number { 0 }
fn fib(1) number { 1 }
fn fib(n number) number { fib(n - 1) + fib(n - 2) }
```

Consequences recorded now, ahead of implementation:

- A top-level name maps to a **clause list**, not a single decl. The
  collector registers `name -> [decl nodes]`.
- Duplicate `fn` names are therefore *not* an error by design. Until clause
  dispatch is designed (pattern params, ordering, arity grouping), v1
  supports a single clause and errors on a duplicate name at collect time —
  the error message should say multi-clause is planned, not "redefinition".
- Open questions parked for the multi-clause arc: dispatch order (top-down
  like Elixir?), arity — is `fib/1` distinct from `fib/2`, literal patterns
  in param position, and how clause heads interact with `param` forms.

## Lowering plan (Zig's pattern, Duni's machinery)

- **Collector pass** (Zig's `scanContainer`, `AstGen.zig:12835`): scan all
  top-level fn decls and register names into a `Namespace` scope *before*
  lowering any body. This is what makes forward references and mutual
  recursion work. Duplicate-name detection happens here (see multi-clause
  above). The parked `decl_val` instruction + `str_tok` data are for exactly
  this: call sites resolve names through the namespace.
- **Params are LocalVals** (Zig's `fnDeclInner`, `AstGen.zig:4215-4251`):
  each param emits a `.param` Dir instruction *and* pushes a `Scope.LocalVal`
  binding the name to that instruction. The body is lowered with the params
  scope as parent. No new scope kind for the body — params reuse the existing
  cursor machinery; their value is a `.param` instruction instead of a bound
  expression.
- **Duplicate param names error in AstGen, not the parser.** Same boundary
  rule as `=` patterns: the parser records shape, never validates names. The
  check is free where params push LocalVals — walk the params built so far,
  error on a name hit. Rebinding a param *inside the body* stays legal
  (ordinary rebind).
- Each fn body becomes its own Dir sub-body (same mechanism as blocks).
  Per-function Sema produces per-function Air.
- Return type resolves without params in scope — `typeExpr` is a bare
  identifier, so Zig's "return type sees params" machinery has no Duni
  equivalent to build.

## Top level

Bare statements remain an implicit main, with `fn` decls allowed alongside.
Script style keeps every existing test green; `fn main` as a required entry
point is revisited later.

## Extern functions — host imports

`extern fn` is the FFI mechanism, and it **replaces `:zig.` entirely** — one
mechanism, no magic atoms. Extern declarations live in `lib/*.duni` as
ordinary Duni source; the compiler never learns a host function's name
(the "stdlib in the language" rule).

```duni
extern fn print(x number) number
```

Proto, no body, newline-terminated.

- **Wasm imports are two-level names.** The binary format requires
  `(import "module" "field" ...)` — there is no bare-name import. The
  embedder (browser `instantiate` object, wasmtime linker) supplies the
  function under exactly that key.
- **v1 has no module syntax.** The module defaults to `"host"`; the runtime
  glue provides a `host` object. Explicit syntax
  (`extern "wasi_snapshot_preview1" fn fd_write(...)`) is only ever needed
  for interfaces whose module name we don't control — WASI. That's a later,
  purely additive arc.
- **AST shape** (updated with the reversal): a bare `fn_proto` decl, no
  wrapper node — Zig's exact model (extern fns are proto-only `fn_proto`,
  never `fn_decl`). The `extern` keyword is the token before the proto's
  `fn`; `firstToken` reaches back over it. The collector, fn-type interning,
  and call sites don't care which declaration form a name came from — a
  root-level proto without a body *is* the extern declaration. When the
  explicit module string arc lands, the string gets a slot in `Node.FnProto`
  (Zig's `lib_name` is the analog); `.none` defaults to `"host"`.
- **Lowering:** collector registers the name identically to `fn`; AstGen
  emits a fn-type-only decl and skips body lowering (Zig's exact split,
  `AstGen.zig:4052`); Sema interns the fn type, nothing to analyze; WatGen
  emits the `(import ...)`.
- **WatGen ordering rule:** imports must precede all function definitions —
  imported functions occupy the first indices in the wasm function index
  space.

## Consciously not doing (Zig carries these; Duni skips)

callconv, align, addrspace, linksection, `anytype` params, comptime params,
varargs, `noalias`, export, inferred error sets, and `pub` — the grammar has
no visibility keyword; everything is public for now. (extern is *in* scope —
see above; only the explicit module string is deferred.)

## Staging — historical

> The plan this feature was built against, kept for the reasoning. Stages A
> through B½ landed; C is partial — Sema folds but does not yet emit runtime
> arithmetic (see [Sema](./sema.md)).

- **A — syntax. Done.** Scanner: `keyword_fn`, `comma`. Parser: fn decl /
  extern fn / call suffix at the Pratt `call` precedence, plus
  `grouped_expression` and the stored-closer spans. Parser tests assert
  node structure.
- **B — AstGen.** Namespace scope + collector, `func`/`param`/`call` Dir
  instructions, `decl_val` gets its producer, bodies as sub-bodies.
- **B½ — extern end-to-end.** `extern fn print(x number) number` +
  `print(42)` is the cheapest complete call path: collector, fn type in the
  InternPool, call-site type check, WAT import + `call` — with no body
  lowering, no param scopes, no runtime arithmetic. Land this before
  `fnDeclInner`-style body lowering.
- **C — Sema.** Fn types in the InternPool, `typeExpr` resolution, per-fn
  Air, arg coercion at call sites (same machinery as the ret boundary).
  Runtime values arrive: fold when all operands are comptime, emit a real
  Air instruction when any operand is runtime. Air grows `.arg`, `.call`,
  runtime arithmetic.
- **D — WatGen.** One `(func $name (param f64) ...)` per function, params
  map 1:1 to WAT params, `call $name`, runtime arithmetic (`f64.add` …).
  Reference: Zig's own wasm backend, `zig/src/arch/wasm/CodeGen.zig`.
  Validate with `wat2wasm` + `wasmtime` like the strings arc.
