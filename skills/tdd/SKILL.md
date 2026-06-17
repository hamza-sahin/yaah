---
name: tdd
description: Test-driven development with red-green-refactor loop. Use when user wants to build features or fix bugs using TDD, mentions "red-green-refactor", wants integration tests, or asks for test-first development.
---

# Test-Driven Development

## Philosophy

**Core principle**: Tests should verify behavior through public interfaces, not implementation details. Code can change entirely; tests shouldn't.

**Good tests** are integration-style: they exercise real code paths through public APIs. They describe _what_ the system does, not _how_ it does it. A good test reads like a specification - "user can checkout with valid cart" tells you exactly what capability exists. These tests survive refactors because they don't care about internal structure.

**Bad tests** are coupled to implementation. They mock internal collaborators, test private methods, or verify through external means (like querying a database directly instead of using the interface). The warning sign: your test breaks when you refactor, but behavior hasn't changed. If you rename an internal function and tests fail, those tests were testing implementation, not behavior.

See [tests.md](tests.md) for examples and [mocking.md](mocking.md) for mocking guidelines.

## The Iron Law

**No production code without a failing test first.** Write the test, **run it, and watch it fail for the right reason** before writing any implementation. Any production code written before its failing test is deleted and rewritten test-first — no exceptions, no "I'll add the test after." A test you never watched fail is not a test; it may be asserting nothing, importing wrong, or passing by accident.

## Anti-Pattern: Horizontal Slices

**DO NOT write all tests first, then all implementation.** This is "horizontal slicing" - treating RED as "write all tests" and GREEN as "write all code."

This produces **crap tests**:

- Tests written in bulk test _imagined_ behavior, not _actual_ behavior
- You end up testing the _shape_ of things (data structures, function signatures) rather than user-facing behavior
- Tests become insensitive to real changes - they pass when behavior breaks, fail when behavior is fine
- You outrun your headlights, committing to test structure before understanding the implementation

**Correct approach**: Vertical slices via tracer bullets. One test → one implementation → repeat. Each test responds to what you learned from the previous cycle. Because you just wrote the code, you know exactly what behavior matters and how to verify it.

```
WRONG (horizontal):
  RED:   test1, test2, test3, test4, test5
  GREEN: impl1, impl2, impl3, impl4, impl5

RIGHT (vertical):
  RED→GREEN: test1→impl1
  RED→GREEN: test2→impl2
  RED→GREEN: test3→impl3
  ...
```

## Workflow

### 1. Planning

When exploring the codebase, use the project's domain glossary so that test names and interface vocabulary match the project's language, and respect ADRs in the area you're touching.

Before writing any code:

- [ ] Settle what interface changes are needed — ask the user **if interactive**; if requirements are already locked (a PRD / `CONTEXT.md` / ADRs from an autonomous pipeline), decide from those and do NOT prompt
- [ ] Settle which behaviors to test, prioritized — same rule: ask if interactive, else derive from the locked requirements
- [ ] Identify opportunities for [deep modules](deep-modules.md) (small interface, deep implementation)
- [ ] Design interfaces for [testability](interface-design.md)
- [ ] List the behaviors to test (not implementation steps)
- [ ] Approve the plan — the user when interactive; otherwise **the locked requirements are the approval**, so proceed without prompting

When interactive, ask: "What should the public interface look like? Which behaviors are most important to test?" When requirements are already locked, skip the question and plan from them.

**You can't test everything.** Pick the behaviors that matter most — interactively with the user, or from the locked requirements when running non-interactively. Focus testing effort on critical paths and complex logic, not every possible edge case.

### 2. Tracer Bullet

Write ONE test that confirms ONE thing about the system:

```
RED:   Write test for first behavior → RUN it → watch it FAIL for the right reason
       (the behavior is genuinely missing — not a typo, import error, or wrong assertion)
GREEN: Write minimal code to pass → RUN it → watch it PASS, output clean,
       no other test broken
```

This is your tracer bullet - proves the path works end-to-end. **Verify RED and GREEN by actually running the test both times** — never assume the outcome. A test that passed on its first run never proved anything failed.

### 3. Incremental Loop

For each remaining behavior:

```
RED:   Write next test → RUN → watch it fail for the right reason
GREEN: Minimal code to pass → RUN → passes, nothing else broken
```

Rules:

- One test at a time
- Only enough code to pass current test
- Don't anticipate future tests
- Keep tests focused on observable behavior

### 4. Refactor

After all tests pass, look for [refactor candidates](refactoring.md):

- [ ] Extract duplication
- [ ] Deepen modules (move complexity behind simple interfaces)
- [ ] Apply SOLID principles where natural
- [ ] Consider what new code reveals about existing code
- [ ] Run tests after each refactor step

**Never refactor while RED.** Get to GREEN first.

## Checklist Per Cycle

```
[ ] RED observed: test was RUN and failed for the right reason before any production code
[ ] Test describes behavior, not implementation
[ ] Test uses public interface only
[ ] Test would survive internal refactor
[ ] Code is minimal for this test
[ ] No speculative features added
[ ] GREEN observed: test was re-RUN and passes; no other test broke
```
