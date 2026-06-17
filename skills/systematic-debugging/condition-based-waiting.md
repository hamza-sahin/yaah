# Condition-Based Waiting

## Overview

Flaky tests often guess at timing with arbitrary delays. This creates race conditions where tests pass on fast machines but fail under load or in CI.

**Core principle:** Wait for the actual condition you care about, not a guess about how long it takes.

## When to Use

- Tests have arbitrary delays (`setTimeout`, `sleep`, `time.sleep()`)
- Tests are flaky (pass sometimes, fail under load)
- Tests time out when run in parallel
- Waiting for async operations to complete

**Don't use when** testing actual timing behavior (debounce, throttle intervals) — but always
document WHY an arbitrary timeout is needed.

## Core Pattern

```typescript
// ❌ BEFORE: Guessing at timing
await new Promise(r => setTimeout(r, 50));
const result = getResult();
expect(result).toBeDefined();

// ✅ AFTER: Waiting for the condition
await waitFor(() => getResult() !== undefined);
const result = getResult();
expect(result).toBeDefined();
```

## Quick Patterns

| Scenario | Pattern |
|----------|---------|
| Wait for event | `waitFor(() => events.find(e => e.type === 'DONE'))` |
| Wait for state | `waitFor(() => machine.state === 'ready')` |
| Wait for count | `waitFor(() => items.length >= 5)` |
| Wait for file | `waitFor(() => fs.existsSync(path))` |
| Complex condition | `waitFor(() => obj.ready && obj.value > 10)` |

## Implementation

Generic polling function (adapt to your language/test framework):
```typescript
async function waitFor<T>(
  condition: () => T | undefined | null | false,
  description: string,
  timeoutMs = 5000
): Promise<T> {
  const startTime = Date.now();
  while (true) {
    const result = condition();
    if (result) return result;
    if (Date.now() - startTime > timeoutMs) {
      throw new Error(`Timeout waiting for ${description} after ${timeoutMs}ms`);
    }
    await new Promise(r => setTimeout(r, 10)); // Poll every 10ms
  }
}
```

## Common Mistakes

- **❌ Polling too fast** (`setTimeout(check, 1)` — wastes CPU) → poll every ~10ms.
- **❌ No timeout** (loops forever) → always include a timeout with a clear error.
- **❌ Stale data** (cache state before loop) → call the getter inside the loop for fresh data.

## When an Arbitrary Timeout IS Correct

```typescript
await waitForEvent(manager, 'TOOL_STARTED'); // First: wait for the triggering condition
await new Promise(r => setTimeout(r, 200));   // Then: wait for known timed behavior (2×100ms ticks)
```

Requirements: (1) first wait for the triggering condition, (2) base the delay on known timing,
not a guess, (3) comment explaining WHY.

## Real-World Impact

- Fixed 15 flaky tests across 3 files; pass rate 60% → 100%; execution 40% faster; no more races.

---

*Vendored into yaah from [obra/superpowers](https://github.com/obra/superpowers) (MIT).*
