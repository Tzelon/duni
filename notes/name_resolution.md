# Name resolution

## What it is

Name resolution is the part of AstGen that turns **textual identifiers**
into IR references. It runs during AstGen's AST walk, before Sema sees
an instruction.

Name resolution:
- Maintains a chain of lexical scopes.
- Looks up identifiers by walking the chain.
- Pushes new bindings onto the chain. Rebinding an existing name is
  allowed (Elixir-style) — the new binding shadows the old one.
- Detects use of undeclared identifiers.

## Where it lives

```
  Parser        AstGen         Sema
    │            │              │
    ▼            ▼              ▼
   AST   ────► DIR  ──────►   AIR
         (names → refs)
```

By the time DIR reaches Sema, **textual names are gone** — every operand is
an `Inst.Ref` pointing at a previous instruction.

## The scope chain

AstGen threads a `Scope` chain through the walk. Each scope has a `parent`
link pointing one level outward.

```
  tip (innermost)                                          root (outermost)
       │                                                          │
       ▼                                                          ▼
  LocalVal "y"  ──►  LocalVal "x"  ──►  GenDir  ──►  Namespace  ──►  Top
                          (parent links)
```

To look up a name, start at the tip and follow `parent` links. The **first
match wins** — that's why inner bindings shadow outer ones. (Today only
`LocalVal` and `Top` exist; `GenDir`/`Namespace` arrive with blocks and
containers.)

A new binding pushes one more node onto the tip. Leaving a block pops the
tip back to where it was.

## The cursor — how the tip travels

Because `=` is an *expression*, a bind inside an operand must be visible to
its sibling (`(x = 1) + x`), so Zig's pass-scope-down/return-scope-up shape
doesn't fit. Instead the tip lives in a `Scope.Cursor { tip: *Scope }` and
every lowering function receives `*Cursor` — a pointer to the *caller's*
cursor variable:

- **Bind** writes `cursor.tip = &new_local_val.base` — the mutation travels
  through the shared cursor, so later siblings and statements see it.
- **Lookup** walks from `cursor.tip`.
- **Blocks (future)** copy the cursor (`var inner = .{ .tip = cursor.tip }`)
  and pass `&inner` down — leaving the block is just the copy dying with its
  stack frame. Scope exit stays structural, nothing to restore.

`LocalVal` nodes are allocated from `scope_arena` on AstGen and freed all at
once after `generate` — the chain holds pointers, so notes need stable
addresses for exactly the duration of lowering.

## Example 1 — happy path

Source: `x = 1; x + 2`

```
Step          Action                              DIR
─────────    ─────────────────────────────────   ─────────────────
bind x = 1   emit, push LocalVal "x" → %0        %0 = int 1
x            lookup "x" → %0 (reuse, no emit)    —
2            emit                                 %1 = int 2
+            emit                                 %2 = add %0 %1
```

Final DIR has no names:

```
%0 = int 1
%1 = int 2
%2 = add %0 %1
```

## Example 2 — rebinding

Source: `x = 1; x = 2; x`

```
Step          Action                              DIR
─────────    ─────────────────────────────────   ─────────────────
bind x = 1   emit, push LocalVal "x" → %0        %0 = int 1
bind x = 2   emit, push LocalVal "x" → %1        %1 = int 2
x            lookup "x" → %1 (first match wins)  —
```

No check on bind — a rebind is just another push. The chain after both
binds:

```
LocalVal "x" → %1  ──►  LocalVal "x" → %0  ──►  Top
```

Lookup starts at the tip, so the newer binding wins; the older one is
unreachable but harmless.

## Example 3 — undeclared identifier

Source: `x + 1`

```
Step          Action                              Result
─────────    ─────────────────────────────────   ─────────────────────────
x            lookup "x" walks to Top, no match   ERROR
                                                  "use of undeclared
                                                   identifier 'x'"
```

This is the only name-resolution error: with rebinding allowed there is
no redeclaration check.
