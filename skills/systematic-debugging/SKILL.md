---
name: systematic-debugging
description: Use when encountering any bug, test failure, failing check, or unexpected behavior, BEFORE proposing fixes. A four-phase root-cause discipline (investigate → pattern → hypothesis → implement) that replaces guess-and-retry. Bundles root-cause-tracing, defense-in-depth, condition-based-waiting, and find-polluter.sh.
---

# Systematic Debugging

## Overview

Random fixes waste time and create new bugs. Quick patches mask underlying issues.

**Core principle:** ALWAYS find root cause before attempting fixes. Symptom fixes are failure.

**Violating the letter of this process is violating the spirit of debugging.**

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If you haven't completed Phase 1, you cannot propose fixes.

## When to Use

Use for ANY technical issue: test failures, failing checks, bugs, unexpected behavior,
performance problems, build failures, integration issues.

**Use this ESPECIALLY when:**
- Under time pressure (emergencies make guessing tempting)
- "Just one quick fix" seems obvious
- You've already tried multiple fixes
- Previous fix didn't work
- You don't fully understand the issue

**Don't skip when:**
- Issue seems simple (simple bugs have root causes too)
- You're in a hurry (rushing guarantees rework)
- A check is red and re-running the same change "might" fix it (it won't)

## The Four Phases

You MUST complete each phase before proceeding to the next.

### Phase 1: Root Cause Investigation

**BEFORE attempting ANY fix:**

1. **Read error messages carefully** — don't skip errors/warnings; they often contain the
   exact solution. Read stack traces completely. Note line numbers, file paths, error codes.
2. **Reproduce consistently** — can you trigger it reliably? Exact steps? Every time? If not
   reproducible → gather more data, don't guess.
3. **Check recent changes** — what changed that could cause this? `git diff`, recent commits,
   new dependencies, config changes, environmental differences.
4. **Gather evidence in multi-component systems** — when the system has multiple components
   (CI → build → sign, API → service → DB), add diagnostic instrumentation at EACH component
   boundary (log what data enters/exits, verify env/config propagation, check state at each
   layer). Run once to gather evidence showing WHERE it breaks, THEN investigate that component.
5. **Trace data flow** — when the error is deep in the call stack, trace backward: where does
   the bad value originate? What called this with the bad value? Keep tracing up to the source.
   Fix at the source, not the symptom. See [root-cause-tracing.md](root-cause-tracing.md).

### Phase 2: Pattern Analysis

1. **Find working examples** — locate similar working code in the same codebase.
2. **Compare against references** — if implementing a pattern, read the reference COMPLETELY,
   every line, before applying.
3. **Identify differences** — list every difference between working and broken, however small.
   Don't assume "that can't matter."
4. **Understand dependencies** — what other components, settings, config, environment does this
   need? What assumptions does it make?

### Phase 3: Hypothesis and Testing

1. **Form a single hypothesis** — state clearly: "I think X is the root cause because Y." Be
   specific, not vague.
2. **Test minimally** — make the SMALLEST possible change to test the hypothesis. One variable
   at a time. Don't fix multiple things at once.
3. **Verify before continuing** — worked? → Phase 4. Didn't? → form a NEW hypothesis; DON'T pile
   more fixes on top.
4. **When you don't know** — say "I don't understand X." Don't pretend. Research more.

### Phase 4: Implementation

1. **Create a failing test case** — simplest possible reproduction, automated if possible. MUST
   have it before fixing. Use the `tdd` skill for writing the proper failing test.
2. **Implement a single fix** — address the root cause, ONE change at a time, no "while I'm here"
   improvements, no bundled refactoring.
3. **Verify the fix** — test passes now? No other tests broken? Issue actually resolved?
4. **If the fix doesn't work** — STOP. Count fixes tried. If < 3: return to Phase 1 with the new
   information. If ≥ 3: STOP and question the architecture (next step).
5. **If 3+ fixes failed: question the architecture.** Pattern indicating an architectural
   problem: each fix reveals new shared state/coupling elsewhere; fixes need "massive
   refactoring"; each fix creates new symptoms. STOP and question fundamentals — is the pattern
   sound, or are we sticking with it through inertia? **Surface the architectural question to the
   caller before attempting more fixes** (in an autonomous pipeline, return a BLOCKED status with
   the concern — do NOT loop). This is NOT a failed hypothesis; it's a wrong architecture.

## Red Flags — STOP and follow process

If you catch yourself thinking:
- "Quick fix for now, investigate later"
- "Just try changing X and see if it works"
- "Add multiple changes, run tests"
- "Skip the test, I'll manually verify"
- "It's probably X, let me fix that"
- "I don't fully understand but this might work"
- "Pattern says X but I'll adapt it differently"
- Proposing solutions before tracing data flow
- **"One more fix attempt" (when already tried 2+)**
- **Each fix reveals a new problem in a different place**

**ALL of these mean: STOP. Return to Phase 1.** If 3+ fixes failed: question the architecture.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "Issue is simple, don't need process" | Simple issues have root causes too. Process is fast for simple bugs. |
| "Emergency, no time for process" | Systematic debugging is FASTER than guess-and-check thrashing. |
| "Just try this first, then investigate" | First fix sets the pattern. Do it right from the start. |
| "I'll write the test after confirming the fix works" | Untested fixes don't stick. Test first proves it. |
| "Multiple fixes at once saves time" | Can't isolate what worked. Causes new bugs. |
| "Reference too long, I'll adapt the pattern" | Partial understanding guarantees bugs. Read it completely. |
| "I see the problem, let me fix it" | Seeing symptoms ≠ understanding root cause. |
| "Re-run the build, it'll probably pass" | A failing check is a signal, not noise. Re-running the same change is not a fix. |
| "One more fix attempt" (after 2+ failures) | 3+ failures = architectural problem. Question the pattern, don't fix again. |

## Quick Reference

| Phase | Key Activities | Success Criteria |
|-------|---------------|------------------|
| **1. Root Cause** | Read errors, reproduce, check changes, gather evidence, trace data flow | Understand WHAT and WHY |
| **2. Pattern** | Find working examples, compare | Identify differences |
| **3. Hypothesis** | Form one theory, test minimally | Confirmed or new hypothesis |
| **4. Implementation** | Create test, single fix, verify | Bug resolved, tests pass, nothing else broken |

## When the process reveals "no root cause"

If investigation reveals the issue is truly environmental, timing-dependent, or external:
document what you investigated, implement appropriate handling (retry, timeout with a clear
error, condition-based wait), and add logging for future investigation. **But:** 95% of "no
root cause" cases are incomplete investigation.

## Supporting Techniques (in this directory)

- **[root-cause-tracing.md](root-cause-tracing.md)** — trace a bug backward through the call
  stack to its original trigger; includes `find-polluter.sh` for bisecting which test pollutes
  shared state (useful for order-dependent failures across independently-built changes).
- **[defense-in-depth.md](defense-in-depth.md)** — after finding the root cause, add validation
  at every layer the bad data passes through to make the bug structurally impossible.
- **[condition-based-waiting.md](condition-based-waiting.md)** — replace arbitrary timeouts with
  condition polling to kill flaky timing-dependent tests (acute when tests run under parallel load).

Related: the `tdd` skill (Phase 4 failing test); re-run the configured checks to verify the fix
before claiming success.

## Real-World Impact

- Systematic approach: 15–30 minutes to fix. Random fixes: 2–3 hours of thrashing.
- First-time fix rate: ~95% vs ~40%. New bugs introduced: near zero vs common.

---

*Vendored into yaah from [obra/superpowers](https://github.com/obra/superpowers) (MIT),
adapted for yaah (the `tdd` skill name; autonomous-pipeline escalation instead of a mid-run
human prompt). Kept self-contained so the forge pipeline works the moment you clone it.*
