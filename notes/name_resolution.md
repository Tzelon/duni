# Name resolution

## What it is

Name resolution is the part of AstGen that turns **textual identifiers**
into IR references. It runs during AstGen's AST walk, before Sema sees
an instruction.

Name resolution:
- Maintains a chain of lexical scopes.
- Looks up identifiers by walking the chain.
- Pushes new bindings onto the chain.
- Detects shadowing / redeclaration errors.

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
match wins** — that's why inner bindings shadow outer ones.

A new binding pushes one more node onto the tip. Leaving a block pops the
tip back to where it was.

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

## Example 2 — shadow error

Source: `x = 1; x = 2`

```
Step          Action                              Result
─────────    ─────────────────────────────────   ─────────────────────────
bind x = 1   emit, push LocalVal "x" → %0        %0 = int 1
bind x = 2   shadow check finds "x" in chain     ERROR
                                                  "redeclaration of 'x'"
```

DIR is never emitted; AstGen reports the error and stops.
