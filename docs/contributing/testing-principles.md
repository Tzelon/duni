# Testing principles

Most Duni tests are data-driven case files: one `.duni` file per behavior,
discovered automatically by the harness (`test/cases.zig`). Prefer many small
cases over a few long ones — each case should be able to fail for exactly one
reason, and its filename should say which. Tests run through the real compiler
end to end; nothing is mocked.

## Test flavor decision matrix

Choose the lightest flavor that can falsify the behavior. For a compiler that is
usually a case file, not a unit test.

| Flavor                                                                    | Use when                                                                                                                                                                          | Avoid when                                                                                                              |
| ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `test/cases/run/` (`// run`) — compile, assemble, execute, compare stdout | The behavior is observable by running a program. The default for anything a user could write: arithmetic, calls, argument order, control flow.                                    | The thing under test produces no output, or the point is the shape of the emitted code rather than its result.          |
| `test/cases/compile_errors/` (`// error`) — byte-exact stderr, exit 1     | Any diagnostic: bad syntax, type mismatches, arity errors, undeclared names. Also the home for every crash you fix.                                                               | Never. If the compiler should reject it, this is the flavor.                                                            |
| `test/cases/wat/` (`// wat`) — golden emitted text                        | The emitted shape _is_ the contract: import emission, `void` return, negative zero — anything where two different WATs would both run but only one is right.                      | The program runs and prints something. Golden WAT breaks on unrelated codegen changes; each file is a maintenance bill. |
| In-file `test` block (`zig build test-unit`)                              | The unit has no source-level trigger yet, or the assertion is on an internal structure: `InternPool` deduplication, scanner token streams, `Type` round-trips, `@sizeOf` budgets. | A `.duni` file could express the same thing. Then it is a case file.                                                    |

### Choosing between them

- **Default to a case file.** A `test` block covers what you thought of while writing the code,
  a case file also gets written for what you didn't.
  When both flavors could work, the case file wins.
- **Every fixed bug gets a case file, not a unit test.** The bug arrived as a
  `.duni` file someone typed — reproduce it in the medium it came in.
- **Prefer `run` over `wat`.** Golden text fails when codegen changes
  legitimately. Use `wat` when the emitted structure is the actual claim, and
  let `run` cover the rest.
- **Byte-exactness in `compile_errors` is a feature.** It pins message wording,
  which is what keeps error text from rotting — and error text is the interface
  users and agents iterate against.

### In-file `test` blocks

- **Each stage's test takes that stage's input by hand.** Build a `Dir` value
  directly to test `Sema`; don't chain `Ast.parse` → `AstGen` to produce it.
  Chained setup means a parser change breaks a `Sema` test and teaches you
  nothing about `Sema`.
- **One case per distinct code path, in a single `test` block** — not several
  categorized blocks covering the same path from different angles.
- Don't test what the type system already guarantees. Distinct index enums like
  `Node.Index` and `ExtraIndex` already make whole classes of assertion
  impossible to fail.

## Principles

- **A regression test is a file.** Adding one must stay as cheap as dropping a
  `.duni` file into `test/cases/`. If a test needs Zig code to exist, that is a
  gap in the harness, not a reason to skip the test.
- **Test through the real compiler.** No mocking a stage, no substituting a fake
  `Sema`. Cases run the whole pipeline and assert on what comes out. The bugs
  that matter live in the seams between stages, and a mocked seam cannot have
  them.
- **Assert on what leaves the compiler** — stdout, emitted WAT, diagnostics.
  Internal structures belong to in-file `test` blocks, and only when there is no
  source-level way to reach them.
- **Never accept a golden you have not read.** Generating expected WAT by
  running the compiler and pasting the output pins whatever the compiler does
  today, bug included. Read it, decide it is right, then paste it.
- **Cover the negative space.** Every stage needs cases feeding it input it must
  reject. All twenty entries in `bugs/README.md` are valid-input assumptions
  meeting invalid input — that is where the interesting bugs are, not on the
  happy path.
- **Absence proves nothing on its own.** A case showing a diagnostic is gone is
  only meaningful beside one showing it still fires where it should. Otherwise
  deleting the check passes both.
- **One behavior per case file, and the filename is the test name.**
  `call_arity_mismatch.duni` says what broke before you open it. Case names are
  often all you get in failure output.
- **A skipped case is not a passing case.** When `wat2wasm` or `node` is
  missing, every `// run` case skips and the suite still reports success. Treat
  the skip line as a failure — see [checks](./setup/checks.md).
- **Keep test output clean.** No `log.*` or `std.debug.print` on any path a case
  exercises. Stray output breaks byte-exact comparison, which is the mechanism
  that keeps diagnostics honest.

## Examples

### Goldens that cannot fail

A `// wat` case pasted straight from compiler output asserts only that the
compiler still does what it did. Argument order is the classic case — this WAT
looks fine, and it was wrong (`bugs/17`):

```
// Bad — pasted without reading. Swapped arguments still pass.
// wat
//
// (module
//   (func $main (result f64)
//     f64.const 3
//     f64.const 10
//     call $sub
```

The behavior is observable, so assert the behavior instead. `run` cases cannot
paper over an ordering bug, because the printed result changes:

```
// Good — test/cases/run/call_argument_order.duni
extern fn print(x number) number
extern fn sub(a number, b number) number

print(sub(10, print(3)))

// run
// expect_stdout=3
// expect_stdout=7
```

Reach for `// wat` when the emitted structure is the claim — that the import is
declared against the `host` module, that `main` is exported — not when a `run`
case would catch the same mistake.

### Absence assertions

A case that only shows an error no longer appears passes just as well when the
check is deleted:

```
// Bad — proves valid input still compiles, not that the stray `}` is caught.
extern fn print(x number) number

print(1 + 1)

// run
// expect_stdout=2
```

Pair it with the case where the diagnostic must fire:

```
// Good — test/cases/compile_errors/stray_rbrace.duni
1 + 1
}
2 + 2

// error
//
// :2:1: error: expected expression, found '}'
```

The pair is the test. One file shows the rule fires, the other shows it does not
fire on valid input — and a stray `}` silently truncating the file (`bugs/06`)
fails both.
