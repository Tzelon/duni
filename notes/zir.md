# Duni AstGen → IR: implementation guide

## What you're building
A pass that walks the `Ast` and produces a flat, untyped, name-resolved IR. No
types (that's Sema), no optimization, no result-location semantics. Just:
resolve names, parse literals, erase syntax-only nodes, emit a flat instruction
stream. This is the canonicalization + lowering step; in Zig it's the whole of
`AstGen.zig` producing `Zir`.

## 1. The IR data structures (`ir.zig`)
Mirror `Ast`'s layout. Reference: top of `AstGen.zig` (the struct fields) and
`Zir.Inst`.

```
instructions: MultiArrayList(Inst)   // tag + 8-byte data
extra: []u32                          // variable-length payloads
string_bytes: []u8                    // interned names
```

`Inst` = `{ tag: Tag, data: Data }`. Define `Inst.Index = enum(u32)` and
`Inst.Ref` (an index into instructions, or one of a few well-known sentinels
later). Start with `Index` only.

`Data` union, same idea as `Ast.Node.Data`:
`bin: struct { lhs: Ref, rhs: Ref }`, `un: Ref`, `int: u64`,
`str: struct { start: u32, len: u32 }`, `pl_node: struct { payload_index: u32 }`.

Tags to start: `int`, `bin_add/bin_sub/...` (or one `bin_op` + operator enum —
your call), `un_neg`, `un_not`, `decl_val` (name reference), `block`,
`ret`/`call` later.

This is the `Zir`/`Zir.Inst` analogue. You own it, caller `deinit`s — same
contract as `Ast.parse`.

## 2. GenZir + Scope (stripped)
Reference: `const GenZir` and `const Scope` near the bottom of `AstGen.zig`.
**Delete almost everything.**

`GenZir` keeps only:
```
astgen: *AstGen
parent: *Scope
instructions: *ArrayList(Inst.Index)   // shared, stacked
instructions_top: usize
```
Drop `is_comptime`, `break_result_info`, all the RLS/label/continue fields. Keep
`makeSubBlock`, `unstack`, `instructionsSlice`, `instructions_top` — that's the
scratch-stacking mechanism (same pattern as your parser's `scratch`).

`Scope` variants you need now: `top`, `gen_zir`, `local_val` (a name →
`Inst.Index` binding), and later `namespace`. Reference the `Scope.LocalVal`
struct and `Scope.unwrap()`/`find_scope` walk pattern.

## 3. The driver (`generate`)
Reference: `pub fn generate`. Yours is far simpler — no `AstRlAnnotate`, no
struct-decl-of-the-file. Just:
```
init AstGen { gpa, arena, tree }
reserve string_bytes[0] = 0   // index 0 = empty string
make a top Scope + root GenZir
for each rootDecls() member: lower it
return Ir{ instructions, extra, string_bytes }   // toOwnedSlice
```

## 4. `expr` — the heart
Reference: `fn expr(gz, scope, ri, node) !Zir.Inst.Ref` — the giant switch.
Yours drops the `ri: ResultInfo` parameter entirely. Signature:
`fn expr(gz: *GenZir, scope: *Scope, node: Ast.Node.Index) !Inst.Index`.

One arm per Duni node tag. Study these arms specifically:
- **binops**: `.add => return simpleBinOp(...)`. Copy `simpleBinOp`'s shape
  (lower lhs, lower rhs, emit one bin inst). Ignore its `rvalue`/cursor lines.
- **`.grouped_expression`**: it's literally `return expr(gz, scope, inner_node)`
  — the node disappears. Do the same.
- **`.number_literal`**: copy `numberLiteral`'s use of
  `std.zig.parseNumberLiteral`, drop the sign/RLS handling. Emit an `int` inst
  with the parsed value.
- **`.negation` / `.bool_not`**: see `negation` and the `.bool_not` arm → one
  unary inst.
- **`.identifier`**: → call your `localVarRef` (below).

Each arm lowers children first, then emits its own inst, then returns that
inst's index. That return value is what your current `traverseTree` is missing.

## 5. Name resolution
Reference: `fn localVarRef`. Strip the closure-tunneling and RLS branches. Core
loop:
```
find_scope: switch (scope.unwrap()) {
    .local_val => |lv| if (lv.name == name) return lv.inst
                       else continue :find_scope lv.parent.unwrap(),
    .gen_zir   => |gz| continue :find_scope gz.parent.unwrap(),
    .namespace => ... (later: look up decls)
    .top       => break :find_scope,   // fall through to "undefined" error
}
return fail(node, "use of undeclared identifier")
```
Names are interned: reference `fn identAsString` + `string_table`/
`string_bytes`. Use it verbatim — it's self-contained.

## 6. Blocks and `bind`
Reference: `fn blockExprStmts`. The key trick: scope is **threaded** — a
declaration returns a *new* scope the following statements see:
```
var scope = parent;
for (statements) |stmt| {
    switch (tag) {
        .bind => scope = try bindDecl(gz, scope, stmt),   // returns new LocalVal scope
        else  => _ = try expr(gz, scope, stmt),
    }
}
```
`bindDecl` (your analogue of `varDecl`, drastically simpler): intern the lhs
name, lower the rhs to an inst, allocate a
`Scope.LocalVal { name, inst, parent }`, return `&sub_scope.base`. Reference
`fn varDecl` only for the *shape* (`detectLocalShadowing` call, sub_scope
creation) — ignore alloc/RLS.

For the block instruction itself, reference `fn setBlockBody`: a block's body is
the stacked instruction slice copied contiguously into `extra`. That's how
nested bodies live in a flat IR.

## 7. Errors
Reference: `compile_errors` field + `failNode`/`appendErrorNode`. Mirror your
parser's recoverable model: `appendError*` accumulates and keeps going; reserve
a hard `error.AnalysisFail` for the rare case you can't continue. Reuse/extend
`ErrorBundle.zig`.

## Order of implementation
1. `ir.zig`: `Inst`, `Data`, `Index`, the three arrays + `deinit`.
2. Stripped `GenZir` + `Scope` (`top`, `gen_zir`, `local_val`).
3. `generate` driver returning an owned `Ir`.
4. `expr` for literals + binops + grouped + unary. Get `example.duni` (pure
   expressions) lowering end-to-end.
5. `identAsString` + `localVarRef`; `identifier` arm.
6. `blockExprStmts` + `bindDecl`; scope threading.
7. `scanContainer` (reference `fn scanContainer`) for top-level forward decls;
   then `fn_decl`/`call`.

## Hard "do not copy" list
`ResultInfo`/`ResultInfo.Loc`, `AstRlAnnotate`, `ref_table`,
`is_comptime`/`block_comptime`, `tunnelThroughClosure`, `restoreErrRetIndex`,
`emitDbgStmt`/source cursor. All Zig-specific weight, none of it
canonicalization. Add later only if Duni grows the feature that needs it.
