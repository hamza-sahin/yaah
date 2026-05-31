# forge — Playbook

Per-phase mechanics, the subagent prompt templates, and edge cases. SKILL.md is the spine; this is the detail. Read once at the start of a run.

## Phase 0 — WORKTREE (isolation)

- Run `bash .claude/skills/forge/scripts/forge-worktree.sh create <slug>`, where `<slug>` is a few words from the seed prompt. Call it via `bash …` so it works regardless of the executable bit. The script branches off the **latest master** (`origin/master` when a remote exists and is reachable; cached `origin/master` or local `master` on fetch failure; local `master` with no remote — in that last case "latest" means the local tip) and creates a sibling worktree under `../.forge-worktrees/` with a kernel-unique name (collision-proof for simultaneous runs).
- Parse the **last two stdout lines**: `WORKTREE=…` and `BRANCH=…`. Put both in the state block.
- **`cd "$WORKTREE"`** and stay there. That makes the worktree the working root for every file edit, sub-skill, and command for the rest of the run — the single mechanism that keeps parallel /forge runs from colliding. Address files relative to it or as `$WORKTREE/…`; never reach back into the main checkout (your original cwd) until Phase 6.
- If the script dies (not a git repo, no master, mktemp/worktree-add failure), that's a hard blocker — report and stop. Do NOT fall back to working on master.

## Phase 1 — GRILL (interactive)

- Call the Skill tool with `grill-with-docs`, feeding it the seed prompt verbatim.
- Let it own the conversation: **one question at a time**, walk each branch of the decision tree, challenge fuzzy terms against `CONTEXT.md`, cross-reference code, and update `CONTEXT.md` / `docs/adr/` **inline** as decisions settle. Because your cwd is `$WORKTREE`, these edits land in the worktree and ride the PR — never the main checkout. Do not batch doc edits.
- ADRs only when all three hold: hard to reverse, surprising without context, the result of a real trade-off.
- **Exit criterion:** every branch resolved and the user has nothing left to push back on ("good" / "ship it" / "that's it" = locked).
- **Carry forward:** a 3–6 bullet locked-requirements summary + the list of doc files touched. Feeds Phase 2 and the handoff.

## Phase 2 — ISSUE

- Call the Skill tool with `to-issues` on the locked plan.
- It drafts **tracer-bullet vertical slices** (each cuts through all layers — schema/API/UI/tests — demoable on its own), marks each AFK/HITL, and publishes in dependency order via `gh issue create` with the repo's triage label (e.g. `ready-for-agent`).
- **Capture** every created issue's number + URL into state.
- **Multiple slices:** process them through Phases 3–6 **one at a time in dependency order** (blockers first). Each slice gets its own worktree, branch, PR, and merge gate; `round`, `worktree`, `branch`, and `pr` are per slice. Re-print the state block when you switch slices. A dependent slice that needs an earlier slice's unmerged code should base its worktree on the blocker's branch rather than master (pass the blocker branch to the script's base, or merge the blocker first).
- Do not modify or close any parent issue.

## Phase 3 — BUILD (handoff → subagent → tdd)

1. Call the Skill tool with `handoff`, scoped to "prompt a fresh agent to implement issue #N via TDD inside `$WORKTREE`." The doc **references the issue by URL** + the grilled decisions/doc changes — it does not restate the issue body.
2. Spawn exactly **one** subagent (Agent tool, `subagent_type: general-purpose` — needs Bash + gh + edit tools). Its prompt = the handoff doc + the build contract below.
3. Read the returned receipt; write `pr` into state. A **missing PR after a retry** is a hard blocker. A **failing check is NOT** a blocker — re-spawn the subagent with tightened guidance (the loop has no cap); only a genuinely unrecoverable failure stops the run.

### Subagent build prompt (template)

```
You are implementing ONE issue end-to-end with TDD, inside an existing git worktree.
Do NOT ask questions — requirements are locked; decide and proceed.

Worktree (your cwd for everything): <$WORKTREE>
Branch (already created, use it): <$BRANCH>
Issue: #<N> — <url>
Locked decisions / handoff: <paste the handoff doc>

Do this:
1. cd into the worktree and confirm you are on <$BRANCH> (git rev-parse --abbrev-ref HEAD).
2. Invoke the /tdd skill and follow it strictly: red → green → refactor, one behavior
   at a time, vertical tracer bullets, behavior tested through public interfaces
   (see tdd/tests.md, tdd/mocking.md). Do NOT create a new branch.
3. Run the repo checks for what you touched (see flutter/AGENTS.md):
   - flutter:  cd flutter && flutter analyze && flutter test <focused paths>
   - DS:       cd design-system/pawbalance/flutter && flutter analyze && flutter test
   - UI change: golden tests (task flutter:golden:test); inspect PNGs before commit
4. Commit (Conventional Commits), push <$BRANCH>, open a PR whose body contains
   "Closes #<N>". Comment the PR URL on issue #<N> via `gh issue comment`.
5. Return ONLY this receipt (no prose):
   branch:  <name>
   pr:      #<M> <url>
   checks:  <each command run + pass/fail>
   summary: <2–4 lines: what you built and any caveat>
```

## Phase 4 — REVIEW (loop, no cap)

- **Invoke `/thermo-nuclear-code-quality-review`** (Skill tool) against the PR branch diff. You orchestrate; it runs its full rubric.
- Apply its bar: code-judo simplifications, the ~1000-line file smell, no scattered special-case branching, abstractions earning their keep, logic in the canonical layer. Prefer few high-conviction findings over many cosmetic nits.
- **Post findings as PR review comments** on the diff and **capture each inline comment's ID** (e.g. from `gh api repos/{owner}/{repo}/pulls/{pr}/comments`). Add a one-line status comment on the issue linking the PR. Then set verdict:
  - **approved** — no presumptive blockers remain → Phase 5.
  - **changes-requested** — re-spawn the TDD subagent (new Agent call) with the fix prompt below, passing the comment IDs. It works in the **same `$WORKTREE` / `$BRANCH`** and **replies on each comment thread** via `gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies -f body=…`. Then re-run this phase, `round += 1`.
- **No cap.** Repeat until approved. Do not escalate to the user; do not give up on ordinary findings.

### Subagent fix prompt (template)

```
Address this code review on PR #<M> (branch <$BRANCH>, worktree <$WORKTREE>) for issue #<N>.
Use /tdd: add/adjust tests for any behavior change; keep red → green → refactor.

Findings to resolve (each with its inline-comment id):
<paste the review findings + comment IDs>

Do this:
1. Work in the EXISTING worktree <$WORKTREE> on <$BRANCH>. Do not create a new branch.
2. Re-run the relevant repo checks (analyze + focused test; golden if UI).
3. Reply on each comment thread you resolved:
   gh api repos/{owner}/{repo}/pulls/<M>/comments/<comment_id>/replies -f body="…how fixed"
4. Push. Return ONLY:
   checks:   <commands + pass/fail>
   resolved: <finding → what changed>
   open:     <anything you intentionally did not change, with why>
```

## Phase 5 — RECAP

Print, in this order:
1. **Decisions** — locked requirements + doc files changed (CONTEXT.md / ADRs).
2. **Issue(s)** — number + URL, label.
3. **PR(s)** — number + URL, branch, worktree path.
4. **Review** — rounds taken, final verdict, any findings deliberately left open (with why).
5. **Checks** — what ran and passed; flag anything not green.
6. **Next** — lead into the merge checkpoint **only if** the reviewer approved and all required checks are green. If any check is red, do NOT offer merge — loop back to Phase 4 with a fix round.

## Phase 6 — MERGE (the one gate)

- Gate condition: reviewer approved AND every required check green. Never present merge otherwise.
- Ask the user to approve merging `$BRANCH` to master (the only approval forge asks for besides grilling).
- **On approval — sync the branch onto latest master, re-verify, THEN merge** (all steps autonomous; the approval was the only user gate). Work in `$WORKTREE` on `$BRANCH`:
  1. `git fetch origin master`. If `$BRANCH` already contains `origin/master`'s tip (no new main changes), skip to step 5.
  2. **Rebase, do not merge:** `git rebase origin/master`. This replays the PR's commits on top of the latest main so no concurrent main change is discarded and no merge commit is introduced. A conflict you cannot resolve cleanly and correctly is a **hard blocker** — surface it and stop (do not force a resolution).
  3. Run `graphify update .` from the worktree root to refresh the knowledge graph for the rebased tree (AST-only, no API cost — per CLAUDE.md). Stage + commit any `graphify-out/` change (Conventional Commit). If `graphify` is unavailable, note it in the recap rather than failing.
  4. `git push --force-with-lease` (the rebase rewrote history, so a plain push is rejected; `--force-with-lease` refuses to clobber if someone else pushed to the PR meanwhile — if it's rejected, re-fetch and reconcile, never plain `--force`).
  5. **Re-run the Phase 4 review loop once as verification.** The rebase merged new main code into the diff's context, so re-review to confirm nothing broke. If it requests changes, run normal no-cap fix rounds (fix subagent on the same branch); after any code change re-run `graphify update .` + commit + push. Loop until the reviewer approves again.
  6. Merge the PR with `gh pr merge` per repo convention.
  7. `cd` back to the main repo clone (you cannot remove a worktree that is your cwd), then `git checkout master && git pull` so the main clone reflects the merge.
  8. Tear the worktree down: `bash .claude/skills/forge/scripts/forge-worktree.sh remove "$WORKTREE"` (it removes the worktree, deletes the `feat/*` branch, and prints `REMOVED=<path>`).
- **On decline / no answer:** leave the PR, branch, and worktree in place and stop — nothing to clean up.
- For multiple slices, run this gate per merged PR; remove each slice's worktree after its own merge.

## Edge cases

- **No git remote / gh not authed:** hard blocker (Phase 0 or 2) — surface and stop.
- **Worktree script fails:** hard blocker — do not fall back to working on master.
- **Trivial / one-liner work:** still run the full chain (issue + subagent PR + review) — do NOT ask the user to skip it. The two-checkpoint contract and the PR/issue link must survive even for small changes.
- **Subagent can't get a check to green:** it reports `open:` with the reason; you re-spawn with tightened guidance. A failed check is never on its own a hard blocker — the loop has no cap. Only a genuinely unrecoverable failure stops the run, and a red check NEVER reaches the merge gate (Phase 5/6 keep looping).
- **User interrupts mid-run:** keep the state block current so the run resumes from the last completed phase; the worktree persists.
- **Multiple issues from Phase 2:** worktree, branch, PR, and `round` are **per issue**; reset `round` to 0 and create a fresh worktree when you start a new slice.
