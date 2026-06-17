# Root Cause Tracing

## Overview

Bugs often manifest deep in the call stack (git init in wrong directory, file created in wrong location, database opened with wrong path). Your instinct is to fix where the error appears, but that's treating a symptom.

**Core principle:** Trace backward through the call chain until you find the original trigger, then fix at the source.

## When to Use

- Error happens deep in execution (not at the entry point)
- Stack trace shows a long call chain
- Unclear where invalid data originated
- Need to find which test/code triggers the problem

If you cannot trace backward (dead end), fix at the symptom point — but that is the exception.

## The Tracing Process

### 1. Observe the Symptom
```
Error: git init failed in ~/project/packages/core
```

### 2. Find Immediate Cause
**What code directly causes this?**
```typescript
await execFileAsync('git', ['init'], { cwd: projectDir });
```

### 3. Ask: What Called This?
```typescript
WorktreeManager.createSessionWorktree(projectDir, sessionId)
  → called by Session.initializeWorkspace()
  → called by Session.create()
  → called by test at Project.create()
```

### 4. Keep Tracing Up
**What value was passed?**
- `projectDir = ''` (empty string!)
- Empty string as `cwd` resolves to `process.cwd()`
- That's the source code directory!

### 5. Find Original Trigger
**Where did the empty string come from?**
```typescript
const context = setupCoreTest(); // Returns { tempDir: '' }
Project.create('name', context.tempDir); // Accessed before beforeEach!
```

## Adding Stack Traces

When you can't trace manually, add instrumentation before the problematic operation:

```typescript
async function gitInit(directory: string) {
  const stack = new Error().stack;
  console.error('DEBUG git init:', {
    directory,
    cwd: process.cwd(),
    nodeEnv: process.env.NODE_ENV,
    stack,
  });

  await execFileAsync('git', ['init'], { cwd: directory });
}
```

**Critical:** Use `console.error()` in tests (not the logger — it may be suppressed). Log
*before* the dangerous operation, not after it fails. Include context (directory, cwd, env
vars, timestamps). Capture the stack with `new Error().stack`.

**Run and capture:**
```bash
npm test 2>&1 | grep 'DEBUG git init'
```

## Finding Which Test Causes Pollution

If something appears during tests but you don't know which test, use the bisection script
[`find-polluter.sh`](find-polluter.sh) in this directory:

```bash
./find-polluter.sh '.git' 'src/**/*.test.ts'
```

It runs tests one-by-one and stops at the first polluter. This is the right tool for
**order-dependent failures** — e.g. a check that passes for a change in isolation but fails once
several independently-built changes are integrated onto one branch.

## Key Principle

**NEVER fix just where the error appears.** Trace back to the original trigger, fix at the
source, then add validation at each layer (see [defense-in-depth.md](defense-in-depth.md)) so the
bug becomes impossible.

---

*Vendored into yaah from [obra/superpowers](https://github.com/obra/superpowers) (MIT).*
