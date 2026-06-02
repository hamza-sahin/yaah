---
name: forge
description: Autonomous end-to-end feature pipeline that chains six skills inside a dedicated git worktree — grill-with-docs → to-prd → to-issues → handoff + a TDD subagent → thermo-nuclear-code-quality-review (review-and-fix loop until clean) → recap → one merge approval. Stack-agnostic and works with GitHub or GitLab; reads per-repo settings from .yaah/config.yml (written by /setup-yaah). Each run branches off the latest default branch in its own worktree, so many runs go in parallel without colliding. Use when the user wants to drive a raw feature or bug prompt all the way to a reviewed, merge-ready PR/MR in one hands-off run, or invokes /forge.
disable-model-invocation: true
argument-hint: "<what to build or fix>"
---

# forge

Drive a raw prompt from idea to a merge-ready PR/MR by orchestrating six existing skills inside a dedicated git worktree. This file is the spine; per-phase mechanics, the subagent prompt templates, and edge cases live in [PLAYBOOK.md](PLAYBOOK.md) — **read it once before Phase 0.**

`/forge <what to build or fix>` — everything after `/forge` is the seed prompt.

## Configuration

forge is stack- and tracker-agnostic. All repo-specific settings live in **`.yaah/config.yml`** at the repo root, written by `/setup-yaah`:

- `cli` — `gh` (GitHub) or `glab` (GitLab); decides every issue/PR/MR command. Recipes for both are in `setup-yaah/scm-commands.md`.
- `default_branch` — the branch to base worktrees on and merge into (blank = auto-detect).
- `checks` — the ordered commands the builder runs and forge re-checks before merge.
- `issue_label` — label applied to forge-created issues (optional).
- `implementer` — which engine runs the Phase 3 build and every Phase 4 fix round. `implementer.engine` is `claude` (default — a Claude Code subagent via the Agent tool), `cursor` (the `cursor-agent` CLI), or `codex` (the OpenAI `codex exec` CLI); the two CLI engines run headlessly inside the worktree. `implementer.model` (cursor/codex, optional) overrides the model (blank = that CLI's default; model ids are engine-specific). A missing block = `claude`. Only the *implementer* changes; grilling, issues, review, and merge are identical across engines. Exact commands + preflight live in [PLAYBOOK.md](PLAYBOOK.md) under "Implementer engines".
- `tools.graphify` — whether Phase 6 refreshes the codebase knowledge graph (legacy top-level `graphify:` is still honored). `tools.rtk` and `tools.caveman` are global token-savers that operate through their own Claude Code hooks; forge takes **no** per-phase action on them — they help transparently, including inside the builder/reviewer subagents. Recipes: `setup-yaah/efficiency-tools.md`.

At Phase 0, read this file. **If it is missing, invoke `/setup-yaah` first**, then continue with the values it wrote. Wherever a phase below says "the tracker CLI", "the checks", or "the default branch", it means the value from this config.

## Non-negotiables (read first)

1. **Invoke the real sub-skill; never reimplement.** Each orchestrator phase is a real Skill-tool call to `grill-with-docs`, `to-prd`, `to-issues`, `handoff`, and `thermo-nuclear-code-quality-review`. The builder runs `/tdd` when the implementer is the **Claude** engine; under a **CLI engine** (`cursor` or `codex`) the builder is that CLI, which cannot call Claude Code skills, so the build prompt inlines the TDD discipline — that is the only sanctioned substitution. Paraphrasing or reinventing any orchestrator sub-skill is a violation of the forge contract.
2. **Autonomous after kickoff.** The user is involved at EXACTLY two moments: the grilling interview (Phase 1) and the merge approval (Phase 6). NEVER prompt the user anywhere else. There is NO review-round cap and NO escalation — the review loop repeats until the reviewer approves, and a failing check just re-spawns the builder. Interrupt ONLY for a true hard blocker (no git repo, no auth, worktree-script failure, an unrecoverable tool failure): report it and stop. NEVER turn ordinary findings or test failures into questions.
3. **Isolated worktree, one per run.** Phase 0 creates a worktree off the latest default branch and you `cd` into it; every file write and command for the rest of the run happens there. The base branch stays untouched until merge, so any number of /forge runs proceed in parallel without colliding.
4. **Merge is the only gate, and the user's call.** NEVER merge before the Phase 6 approval. Present the gate ONLY when the reviewer has approved AND every required check is green. Remove the worktree ONLY after a successful merge.

## Pipeline

```
Phase 0  CONFIG+WT bash <skill-dir>/scripts/forge-worktree.sh create   read config, isolated branch off default, cd in
Phase 1  GRILL     /grill-with-docs                        interactive — lock requirements + docs
Phase 2  PRD+ISSUES /to-prd → /to-issues                   publish PRD parent issue, then child tasks attached to it (task-list + Parent refs)
Phase 3  BUILD     /handoff → implementer (claude|cursor|codex) → /tdd   work child issues one-by-one in ONE PR: 1 commit/issue, check its PRD box, backlink the commit
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
  prd:      #P <url>     parent issue (or: pending)
  issues:   #a #b #c     child tasks — mark ✓ when its commit lands (or: pending)
  pr:       #M <url>     one PR for the whole PRD (or: pending)
  round:    k            (starts at 0; +1 per review round)
  verdict:  pending | changes-requested | approved
```

## Phases (full mechanics in PLAYBOOK.md)

0. **CONFIG + WORKTREE** — Read `.yaah/config.yml` (run `/setup-yaah` first if absent). Then run `bash <forge-skill-dir>/scripts/forge-worktree.sh create <slug>` (slug from the seed; the script auto-detects the default branch, or honors `default_branch` via `FORGE_BASE_BRANCH`). Parse `WORKTREE` and `BRANCH` from the last two stdout lines into state, then `cd "$WORKTREE"` — it is now the working root for every later edit, command, and subagent cwd. Script failure = hard blocker; stop. **If `implementer.engine` is `cursor` or `codex`, also preflight that CLI now** (cursor: `cursor-agent --version` + `CURSOR_API_KEY`/`cursor-agent status`; codex: `codex --version` + `codex login status`); a missing or unauthed CLI is a hard blocker (PLAYBOOK has the exact checks per engine).
1. **GRILL** — Invoke `/grill-with-docs` with the seed. Let it own the interview to completion: one question at a time, challenge terms against `CONTEXT.md`, update `CONTEXT.md` and `docs/adr/` (under `$WORKTREE`) inline as decisions settle. Exit when no decision-tree branch is open. Carry forward a short locked-requirements summary + the doc files touched.
2. **PRD + ISSUES** — First invoke `/to-prd` on the locked plan: it synthesizes the grilled `CONTEXT.md`/ADRs into a PRD and publishes it as the **parent issue** via the tracker CLI from config (`gh issue create` / `glab issue create`) with the configured `issue_label`. Capture the PRD #/URL. Then invoke `/to-issues`, which breaks that PRD into tracer-bullet **child issues** — each references the PRD in its `Parent` field, and the PRD body carries a task-list (`- [ ] #child`) of them all — published in dependency order with the same label. Capture every child #/URL. Both skills run **non-interactively**: requirements were locked in Phase 1, so skip their built-in seam-check / quiz steps and decide from `CONTEXT.md`. The whole PRD becomes ONE PR in Phase 3 — exactly one worktree, one branch, one PR, and one merge gate for the entire PRD; each child issue is a single commit inside it.
3. **BUILD** — Invoke `/handoff` to write a compact handoff (reference the PRD + child issues by URL + the grilled decisions; do NOT restate the issue bodies). Then hand the build prompt (handoff + the build contract in PLAYBOOK.md, carrying the configured `checks` and `cli`) to the **configured implementer engine**: `claude` spawns ONE `general-purpose` subagent whose cwd is `$WORKTREE`; `cursor` / `codex` write the prompt to a `.md` file and run `scripts/forge-implement.sh` headlessly against `$WORKTREE` (**never hand-build the CLI command** — PLAYBOOK has the call). Either way the implementer runs TDD and works the child issues **one-by-one in dependency order on the single `$BRANCH`**: for each child it lands **exactly one commit** whose message carries `Closes #<child>`, then checks that child's box in the PRD task-list and backlinks the commit SHA + PR/MR URL on the child issue. It runs the configured checks, opens ONE PR/MR (body `Closes #<prd>` + `Closes #<each child>`), and returns a strict receipt. Record `pr` (and, for cursor, the session handle) into state.
4. **REVIEW** — Invoke `/thermo-nuclear-code-quality-review` (Skill tool) against the PR/MR branch diff. Post its findings as **inline review comments** on the PR/MR (GitHub) or **MR discussions** (GitLab) using the recipes in `setup-yaah/scm-commands.md`, capturing each comment/discussion ID.
   - **approved** → Phase 5.
   - **changes-requested** → re-run the **configured implementer** with the findings + comment IDs (claude: a fresh fix subagent; cursor: `cursor-agent --resume <session>`; codex: `codex exec resume --last` — each keeps build context; PLAYBOOK has all three). It fixes on the **same `$WORKTREE`/`$BRANCH`**, replies on each comment thread, pushes; then re-run this phase, `round += 1`. **Loop until approved — no cap, no escalation.**
5. **RECAP** — Summarize: locked decisions + doc changes, issue link(s), PR/MR link(s), rounds taken, final verdict, checks run (flag any not green).
6. **MERGE** — Present the gate ONLY if the reviewer approved AND all required checks are green (otherwise keep looping). Ask the user to approve merging `$BRANCH` to the default branch. **On approval, sync-then-verify before merging** (all autonomous — this is still one user gate): in `$WORKTREE`, `git fetch origin <default-branch>`; if it moved, **rebase `$BRANCH` onto `origin/<default-branch>`** (rebase, never a merge commit — keeps concurrent base-branch changes without discarding the PR/MR); if `tools.graphify` (or legacy `graphify`) is true, run `graphify update .` and commit any graph change; `git push --force-with-lease`; then **re-run the Phase 4 review loop once as verification** (no cap — run normal fix rounds if it surfaces anything, re-running graphify after each code change). When that pass is clean, merge the single PR/MR via the tracker CLI — its `Closes` refs auto-close the PRD parent and every child issue. After merge: `cd` to the main repo, `git checkout <default-branch> && git pull`, then `bash <forge-skill-dir>/scripts/forge-worktree.sh remove "$WORKTREE"`. A rebase conflict you cannot resolve cleanly is a hard blocker — surface and stop. If declined, leave everything in place and stop.

## Guardrails (the contract, restated)

- **Invoke every sub-skill for real** — never paraphrase or reimplement, the reviewer included.
- **Config-driven, not hardcoded.** Tracker CLI, checks, default branch, label, `implementer.engine`, and `tools.graphify` all come from `.yaah/config.yml` — never assume a stack, `gh`-vs-`glab`, or which implementer engine.
- **Same prompt, swappable engine — and never hand-build a CLI command.** The build/fix prompts are identical across engines; only delivery changes (Agent tool vs a headless CLI). For `cursor`/`codex` the ONLY supported invocation is writing the prompt to a `.md` file and running `scripts/forge-implement.sh` (it assembles argv safely, wraps the timeout, parses the receipt, prints a `STATUS=ok|fail` block). Hand-assembling the command inline is forbidden — that caused a real `EXIT=127` word-splitting failure. Gate the round on the script's `STATUS=ok`; `STATUS=fail`/`EXIT≠0` is a failed round (re-run, no cap), never silent success. Preflight the chosen CLI at Phase 0; a missing/unauthed CLI is a hard blocker — never silently fall back to claude.
- **No user prompts between Phases 2–5.** Surface only a true hard blocker, then stop.
- **No round cap.** The review loop ends only when the reviewer approves. A failed check is NOT a blocker — re-spawn the builder with tighter guidance.
- **Stay in `$WORKTREE`.** You `cd` in at Phase 0; address files relative to it or as `$WORKTREE/…`. NEVER write to the main checkout — that collides with parallel runs.
- **One worktree + one branch + one PR per PRD.** Every child issue is a single commit on that one branch (`Closes #<child>`); fix rounds reuse the branch; NEVER branch again. There is exactly one merge gate, for the whole PRD.
- **Never merge before Phase 6**, never offer merge with a red check, and remove the worktree only after a successful merge.
- **Sync before merge by rebase, not merge commit.** On approval, rebase `$BRANCH` onto the latest default branch, refresh the graph (if enabled), force-push with `--force-with-lease`, and re-verify with one review pass; only then merge. An unresolvable rebase conflict is a hard blocker.
- **Never claim done if a check was skipped.** The configured `checks` are the subagent's job via `/tdd`; report exactly what ran.
