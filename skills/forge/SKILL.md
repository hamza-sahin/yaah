---
name: forge
description: Autonomous end-to-end feature pipeline that chains five skills inside a dedicated git worktree — grill-with-docs → to-issues → handoff + a TDD subagent → thermo-nuclear-code-quality-review (review-and-fix loop until clean) → recap → one merge approval. Stack-agnostic and works with GitHub or GitLab; reads per-repo settings from .yaah/config.yml (written by /setup-yaah). Each run branches off the latest default branch in its own worktree, so many runs go in parallel without colliding. Use when the user wants to drive a raw feature or bug prompt all the way to a reviewed, merge-ready PR/MR in one hands-off run, or invokes /forge.
disable-model-invocation: true
argument-hint: "<what to build or fix>"
---

# forge

Drive a raw prompt from idea to a merge-ready PR/MR by orchestrating five existing skills inside a dedicated git worktree. This file is the spine; per-phase mechanics, the subagent prompt templates, and edge cases live in [PLAYBOOK.md](PLAYBOOK.md) — **read it once before Phase 0.**

`/forge <what to build or fix>` — everything after `/forge` is the seed prompt.

## Configuration

forge is stack- and tracker-agnostic. All repo-specific settings live in **`.yaah/config.yml`** at the repo root, written by `/setup-yaah`:

- `cli` — `gh` (GitHub) or `glab` (GitLab); decides every issue/PR/MR command. Recipes for both are in `setup-yaah/scm-commands.md`.
- `default_branch` — the branch to base worktrees on and merge into (blank = auto-detect).
- `checks` — the ordered commands the builder runs and forge re-checks before merge.
- `issue_label` — label applied to forge-created issues (optional).
- `tools.graphify` — whether Phase 6 refreshes the codebase knowledge graph (legacy top-level `graphify:` is still honored). `tools.rtk` and `tools.caveman` are global token-savers that operate through their own Claude Code hooks; forge takes **no** per-phase action on them — they help transparently, including inside the builder/reviewer subagents. Recipes: `setup-yaah/efficiency-tools.md`.

At Phase 0, read this file. **If it is missing, invoke `/setup-yaah` first**, then continue with the values it wrote. Wherever a phase below says "the tracker CLI", "the checks", or "the default branch", it means the value from this config.

## Non-negotiables (read first)

1. **Invoke the real sub-skill; never reimplement.** Each phase is a real Skill-tool call to `grill-with-docs`, `to-issues`, `handoff`, `tdd`, and `thermo-nuclear-code-quality-review`. Paraphrasing or reinventing any of them is a violation of the forge contract.
2. **Autonomous after kickoff.** The user is involved at EXACTLY two moments: the grilling interview (Phase 1) and the merge approval (Phase 6). NEVER prompt the user anywhere else. There is NO review-round cap and NO escalation — the review loop repeats until the reviewer approves, and a failing check just re-spawns the builder. Interrupt ONLY for a true hard blocker (no git repo, no auth, worktree-script failure, an unrecoverable tool failure): report it and stop. NEVER turn ordinary findings or test failures into questions.
3. **Isolated worktree, one per run.** Phase 0 creates a worktree off the latest default branch and you `cd` into it; every file write and command for the rest of the run happens there. The base branch stays untouched until merge, so any number of /forge runs proceed in parallel without colliding.
4. **Merge is the only gate, and the user's call.** NEVER merge before the Phase 6 approval. Present the gate ONLY when the reviewer has approved AND every required check is green. Remove the worktree ONLY after a successful merge.

## Pipeline

```
Phase 0  CONFIG+WT bash <skill-dir>/scripts/forge-worktree.sh create   read config, isolated branch off default, cd in
Phase 1  GRILL     /grill-with-docs                        interactive — lock requirements + docs
Phase 2  ISSUE     /to-issues                              create issue(s) via the tracker CLI, capture #/URL
Phase 3  BUILD     /handoff → subagent → /tdd              implement in worktree, open PR/MR, link issue
Phase 4  REVIEW    /thermo-nuclear-code-quality-review     invoke; loop until clean (no cap)
Phase 5  RECAP     summarize the run
Phase 6  MERGE     approve → rebase on latest default branch → graphify + push → verify-review → merge
```

## State block — re-print at every phase transition

```
forge state
  seed:     <one line>
  worktree: <abs path>   (or: pending)
  branch:   <name>       (or: pending)
  issue:    #N <url>     (or: pending)
  pr:       #M <url>     (or: pending)
  round:    k            (starts at 0; +1 per review round)
  verdict:  pending | changes-requested | approved
```

## Phases (full mechanics in PLAYBOOK.md)

0. **CONFIG + WORKTREE** — Read `.yaah/config.yml` (run `/setup-yaah` first if absent). Then run `bash <forge-skill-dir>/scripts/forge-worktree.sh create <slug>` (slug from the seed; the script auto-detects the default branch, or honors `default_branch` via `FORGE_BASE_BRANCH`). Parse `WORKTREE` and `BRANCH` from the last two stdout lines into state, then `cd "$WORKTREE"` — it is now the working root for every later edit, command, and subagent cwd. Script failure = hard blocker; stop.
1. **GRILL** — Invoke `/grill-with-docs` with the seed. Let it own the interview to completion: one question at a time, challenge terms against `CONTEXT.md`, update `CONTEXT.md` and `docs/adr/` (under `$WORKTREE`) inline as decisions settle. Exit when no decision-tree branch is open. Carry forward a short locked-requirements summary + the doc files touched.
2. **ISSUE** — Invoke `/to-issues` on the locked plan. It publishes tracer-bullet vertical slices via the tracker CLI from config (`gh issue create` / `glab issue create`) in dependency order with the configured `issue_label`. Capture each issue #/URL. If it yields multiple slices, drive Phases 3–6 **per slice in dependency order** (blockers first) — one worktree+branch+PR/MR and one merge gate each.
3. **BUILD** — Invoke `/handoff` to write a compact handoff (reference the issue by URL + the grilled decisions; do NOT restate the issue body). Spawn ONE `general-purpose` subagent whose cwd is `$WORKTREE`, prompt = handoff + the build contract in PLAYBOOK.md (which carries the configured `checks` and `cli`). It runs `/tdd`, implements on `$BRANCH`, runs the configured checks, opens a PR/MR with `Closes #<issue>`, comments the PR/MR URL on the issue, and returns a strict receipt. Record `pr` into state.
4. **REVIEW** — Invoke `/thermo-nuclear-code-quality-review` (Skill tool) against the PR/MR branch diff. Post its findings as **inline review comments** on the PR/MR (GitHub) or **MR discussions** (GitLab) using the recipes in `setup-yaah/scm-commands.md`, capturing each comment/discussion ID.
   - **approved** → Phase 5.
   - **changes-requested** → re-spawn the TDD subagent with the findings + comment IDs; it fixes on the **same `$WORKTREE`/`$BRANCH`**, replies on each comment thread, pushes; then re-run this phase, `round += 1`. **Loop until approved — no cap, no escalation.**
5. **RECAP** — Summarize: locked decisions + doc changes, issue link(s), PR/MR link(s), rounds taken, final verdict, checks run (flag any not green).
6. **MERGE** — Present the gate ONLY if the reviewer approved AND all required checks are green (otherwise keep looping). Ask the user to approve merging `$BRANCH` to the default branch. **On approval, sync-then-verify before merging** (all autonomous — this is still one user gate): in `$WORKTREE`, `git fetch origin <default-branch>`; if it moved, **rebase `$BRANCH` onto `origin/<default-branch>`** (rebase, never a merge commit — keeps concurrent base-branch changes without discarding the PR/MR); if `tools.graphify` (or legacy `graphify`) is true, run `graphify update .` and commit any graph change; `git push --force-with-lease`; then **re-run the Phase 4 review loop once as verification** (no cap — run normal fix rounds if it surfaces anything, re-running graphify after each code change). When that pass is clean, merge via the tracker CLI. After merge: `cd` to the main repo, `git checkout <default-branch> && git pull`, then `bash <forge-skill-dir>/scripts/forge-worktree.sh remove "$WORKTREE"`. A rebase conflict you cannot resolve cleanly is a hard blocker — surface and stop. If declined, leave everything in place and stop.

## Guardrails (the contract, restated)

- **Invoke every sub-skill for real** — never paraphrase or reimplement, the reviewer included.
- **Config-driven, not hardcoded.** Tracker CLI, checks, default branch, label, and `tools.graphify` all come from `.yaah/config.yml` — never assume a stack or `gh`-vs-`glab`.
- **No user prompts between Phases 2–5.** Surface only a true hard blocker, then stop.
- **No round cap.** The review loop ends only when the reviewer approves. A failed check is NOT a blocker — re-spawn the builder with tighter guidance.
- **Stay in `$WORKTREE`.** You `cd` in at Phase 0; address files relative to it or as `$WORKTREE/…`. NEVER write to the main checkout — that collides with parallel runs.
- **One worktree + one branch per issue.** Fix rounds reuse them; NEVER branch again mid-loop. Reset `round` to 0 and create a fresh worktree per new slice.
- **Never merge before Phase 6**, never offer merge with a red check, and remove the worktree only after a successful merge.
- **Sync before merge by rebase, not merge commit.** On approval, rebase `$BRANCH` onto the latest default branch, refresh the graph (if enabled), force-push with `--force-with-lease`, and re-verify with one review pass; only then merge. An unresolvable rebase conflict is a hard blocker.
- **Never claim done if a check was skipped.** The configured `checks` are the subagent's job via `/tdd`; report exactly what ran.
