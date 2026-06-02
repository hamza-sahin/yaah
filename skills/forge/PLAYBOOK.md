# forge — Playbook

Per-phase mechanics, the subagent prompt templates, and edge cases. SKILL.md is the spine; this is the detail. Read once at the start of a run. Tracker commands (`gh` vs `glab`) come from `.yaah/config.yml` → `cli`; full recipes for both are in [../setup-yaah/scm-commands.md](../setup-yaah/scm-commands.md).

## Phase 0 — CONFIG + WORKTREE (isolation)

- **Read `.yaah/config.yml`** at the repo root. If it is missing, invoke `/setup-yaah` to create it, then continue with `cli`, `checks`, `default_branch`, `issue_label`, and `tools.graphify` (legacy top-level `graphify:` also honored) from it.
- Run `bash <forge-skill-dir>/scripts/forge-worktree.sh create <slug>`, where `<slug>` is a few words from the seed prompt and `<forge-skill-dir>` is wherever yaah is installed (`~/.claude/skills/forge` for a global install, or `<repo>/.claude/skills/forge` per-project). Call it via `bash …` so it works regardless of the executable bit. The script **auto-detects the default branch** (remote `origin/HEAD`, else local `main`/`master`); set `FORGE_BASE_BRANCH` from `config.default_branch` if you want to force one. It branches off the latest tip of that branch (cached/local fallback on fetch failure) and creates a sibling worktree under `../.forge-worktrees/` with a kernel-unique name (collision-proof for simultaneous runs).
- Parse the **last two stdout lines**: `WORKTREE=…` and `BRANCH=…`. Put both in the state block.
- **`cd "$WORKTREE"`** and stay there. That makes the worktree the working root for every file edit, sub-skill, and command for the rest of the run — the single mechanism that keeps parallel /forge runs from colliding. Address files relative to it or as `$WORKTREE/…`; never reach back into the main checkout (your original cwd) until Phase 6.
- If the script dies (not a git repo, no base branch, mktemp/worktree-add failure), that's a hard blocker — report and stop. Do NOT fall back to working on the base branch.
- **If `implementer.engine` is `cursor` or `codex`**, preflight that CLI before Phase 1 (it is exercised in Phase 3 and every Phase 4 fix round) — see the per-engine preflight block in **Implementer engines** under Phase 3. A missing or unauthed CLI is a hard blocker.

## Phase 1 — GRILL (interactive)

- Call the Skill tool with `grill-with-docs`, feeding it the seed prompt verbatim.
- Let it own the conversation: **one question at a time**, walk each branch of the decision tree, challenge fuzzy terms against `CONTEXT.md`, cross-reference code, and update `CONTEXT.md` / `docs/adr/` **inline** as decisions settle. Because your cwd is `$WORKTREE`, these edits land in the worktree and ride the PR/MR — never the main checkout. Do not batch doc edits.
- ADRs only when all three hold: hard to reverse, surprising without context, the result of a real trade-off.
- **Exit criterion:** every branch resolved and the user has nothing left to push back on ("good" / "ship it" / "that's it" = locked).
- **Carry forward:** a 3–6 bullet locked-requirements summary + the list of doc files touched. Feeds Phase 2 and the handoff.

## Phase 2 — PRD + ISSUES

Two sub-skills, in order, both **non-interactive**: Phase 1 already locked the requirements, so do NOT re-quiz the user — their built-in "check the seams" (`to-prd`) and "quiz the user" (`to-issues`) steps are satisfied by the grilled `CONTEXT.md` / ADRs. Decide from those and proceed.

1. **`/to-prd`** — Call the Skill tool with `to-prd` on the locked plan. It synthesizes `CONTEXT.md` + the ADRs into a PRD (problem, solution, user stories, implementation + testing decisions, out-of-scope) and **publishes it as the parent issue** via the tracker CLI (`gh issue create` / `glab issue create`) with the configured `issue_label`. **Capture the PRD's number + URL into state (`prd`).**
2. **`/to-issues`** — Then call the Skill tool with `to-issues`, passing the PRD. It drafts **tracer-bullet vertical slices** (each cuts through all layers — data/API/UI/tests — demoable on its own), marks each AFK/HITL, and publishes them as **child issues of the PRD**:
   - Each child issue's `Parent` field references the PRD (`#<prd>`).
   - The **PRD body gets a task-list** of the children — one `- [ ] #<child>` per line — so progress is visible on the parent. Write it by editing the PRD body once the children exist (`gh issue edit <prd> --body …` / `glab issue update <prd> --description …`).
   - Publish in dependency order (blockers first) with the configured `issue_label`.
   - **Capture every child issue's number + URL into state (`issues`), in dependency order.**

**One PRD ⇒ one PR.** Unlike the old per-slice model, every child issue is implemented as a single commit on a **single branch / single PR** (Phase 3), and the whole PRD has **one merge gate** (Phase 6). `worktree`, `branch`, `pr`, and `round` are per PRD, not per child. Do not close the PRD or children by hand — the Phase 6 merge auto-closes them via the PR/MR's `Closes` refs; you only write/check the PRD task-list.

## Phase 3 — BUILD (handoff → implementer → tdd)

1. Call the Skill tool with `handoff`, scoped to "prompt a fresh agent to implement the PRD's child issues one-by-one via TDD inside `$WORKTREE`." The doc **references the PRD + every child issue by URL** (in dependency order) + the grilled decisions/doc changes — it does not restate the issue bodies.
2. Deliver the build prompt to the **configured implementer engine** (`implementer.engine`, default `claude`) — exact mechanics in **Implementer engines** below. The prompt = the handoff doc + the build contract below, with `<CHECKS>` and `<CLI>` filled from config (and the `/tdd` line adapted per engine). For a CLI engine (`cursor`/`codex`) write that prompt to a `.md` file and run `forge-implement.sh` — **never hand-build the CLI command**.
3. Read the returned receipt; write `pr` (and, for cursor, the session id) into state. A **missing PR/MR after a retry** is a hard blocker. A **failing check is NOT** a blocker — re-run the implementer with tightened guidance (the loop has no cap); only a genuinely unrecoverable failure stops the run.

### Subagent build prompt (template)

```
You are implementing a whole PRD end-to-end with TDD, inside an existing git worktree.
Do NOT ask questions — requirements are locked; decide and proceed.

Worktree (your cwd for everything): <$WORKTREE>
Branch (already created, use it; NEVER create another): <$BRANCH>
PRD (parent issue): #<P> — <url>
Child issues to implement, IN THIS ORDER (dependency order): #<a> <url>, #<b> <url>, #<c> <url>
Tracker CLI: <CLI>            (gh = GitHub, glab = GitLab)
Checks to run: <CHECKS>       (ordered; each MUST exit non-zero on failure)
Locked decisions / handoff: <paste the handoff doc>

Do this:
1. cd into the worktree and confirm you are on <$BRANCH> (git rev-parse --abbrev-ref HEAD).
2. Work the child issues IN THE GIVEN ORDER. For EACH child:
   a. Invoke the /tdd skill and follow it strictly: red → green → refactor, one behavior
      at a time, vertical tracer bullets, behavior tested through public interfaces
      (see tdd/tests.md, tdd/mocking.md). Do NOT create a new branch.
   b. Run the configured checks for what you touched (the <CHECKS> list, in order). All must pass.
   c. Land EXACTLY ONE commit for this child — squash your red/green/refactor work into it:
      Conventional Commits subject + a body line "Closes #<child>". Push <$BRANCH>.
   d. On the FIRST commit, immediately open the ONE PR/MR (step 3). Later commits: just push to it.
   e. Flip this child's PRD task-list box "- [ ] #<child>" → "- [x] #<child>":
        gh:   gh issue edit <P> --body "<updated PRD body>"
        glab: glab issue update <P> --description "<updated PRD body>"
   f. Backlink on the child issue — comment the commit SHA + the PR/MR URL:
        gh:   gh issue comment <child> --body "Done in <sha> — PR #<M> <url>"
        glab: glab issue note <child> --message "Done in <sha> — MR !<M> <url>"
3. The single PR/MR (opened at the first commit) Closes the PRD AND every child issue:
     gh:   gh pr create --base <DEFAULT_BRANCH> --head <$BRANCH> --title T \
             --body $'Closes #<P>\nCloses #<a>\nCloses #<b>\nCloses #<c>'
     glab: glab mr create --source-branch <$BRANCH> --target-branch <DEFAULT_BRANCH> --title T \
             --description $'Closes #<P>\nCloses #<a>\nCloses #<b>\nCloses #<c>'
4. Return ONLY this receipt (no prose):
   branch:  <name>
   pr:      #<M> <url>
   prd:     #<P> — boxes checked: <a,b,c>
   commits: <one line per child: #<child> → <sha>>
   checks:  <each command run + pass/fail>
   summary: <2–4 lines: what you built and any caveat>
```

### Implementer engines

The build prompt above and the fix prompt in Phase 4 are **engine-agnostic** — the same text runs under any engine. `implementer.engine` is `claude` (default), `cursor`, or `codex`; `implementer.model` (cursor/codex) optionally overrides the model. A missing block ⇒ `claude`. Receipt format and success contract are identical; only *how* the prompt is delivered differs.

#### `claude` (default) — a Claude Code subagent

Spawn exactly **one** subagent via the Agent tool, `subagent_type: general-purpose` (it needs Bash + the tracker CLI + edit tools), cwd `$WORKTREE`, prompt = the build prompt (Phase 3) or the fix prompt (Phase 4). The subagent's final message **is** the receipt. Fix rounds are a fresh Agent call with the fix prompt.

#### `cursor` / `codex` — CLI engines, invoked via `forge-implement.sh`

> **NEVER hand-build the cursor/codex command line.** Hand-assembling it inline is what broke a real run (zsh word-splitting an unquoted `${TO:+…}` timeout, quoting the prompt, `EXIT=127`). Instead: **write the prompt to a `.md` file and call the bundled script.** It assembles argv with bash arrays (no word-splitting), wraps a portable timeout (`timeout`/`gtimeout`/none), feeds the prompt from the file via stdin (no inlining, no `ARG_MAX`, no quoting), parses the receipt per engine, and prints one machine-parseable block.

**Build** (`<forge-skill-dir>` = where yaah is installed, same as `forge-worktree.sh`):
```
PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/forge-prompt-XXXXXX").md"
# write the FULL build prompt (handoff + build contract, /tdd line inlined — see below) into it, then:
bash <forge-skill-dir>/scripts/forge-implement.sh \
  --engine "$ENGINE" --workspace "$WORKTREE" --prompt-file "$PROMPT_FILE" \
  [--model "$MODEL"] [--timeout 3600]
```
**Fix round** (same script, `--mode fix`):
```
bash <forge-skill-dir>/scripts/forge-implement.sh \
  --engine "$ENGINE" --workspace "$WORKTREE" --prompt-file "$FIX_PROMPT_FILE" --mode fix \
  [--session "$SESSION"] [--model "$MODEL"]
```
- **cursor fix:** pass `--session "$SESSION"` (the `SESSION=` value the build printed) to resume that chat; if lost, omit it and the script falls back to `--continue`.
- **codex fix:** omit `--session` — codex has no surfaced id, so the script resumes the worktree's most recent session via `--last` (run from `$WORKTREE`, which the script handles).

**Read the script's tail block** (always the last lines of stdout):
```
===FORGE-IMPLEMENT===
ENGINE=… MODE=… EXIT=… STATUS=ok|fail SESSION=… RECEIPT_FILE=… STDOUT_LOG=… STDERR_LOG=…
```
- `STATUS=ok` → the receipt is in `RECEIPT_FILE` (also echoed between `===RECEIPT===`/`===END RECEIPT===`). For cursor, **save `SESSION` into state** for the fix round.
- `STATUS=fail` or `EXIT≠0` → failed round (read `STDERR_LOG`); re-run with tightened guidance — **no cap**. `EXIT=124` = timed out. A missing/unauthed binary the preflight missed shows as `EXIT=2`/`127` here.

*Preflight* (Phase 0, once per run — hard blocker on failure):
- **cursor:** `cursor-agent --version`; `[ -n "$CURSOR_API_KEY" ] || cursor-agent status`. Install: `curl https://cursor.com/install -fsS | bash`; auth: `cursor-agent login`.
- **codex:** `codex --version`; `codex login status`. Install: `npm i -g @openai/codex`; auth: `codex login` (or `OPENAI_API_KEY`).

*Prompt adaptation (cursor & codex).* Neither CLI has Claude Code skills, so in the prompt file replace the build contract's TDD directive (step 2a — "Invoke the /tdd skill…") — with this inline directive (the per-child loop, one-commit-per-child, task-list, and backlink steps stay verbatim):
> Work strictly test-first in **red → green → refactor** cycles, one behavior at a time. Build **vertical tracer bullets** (a thin slice through every layer), not horizontal layers. Test behavior through **public interfaces**, never implementation details; mock only true external boundaries (network, clock, filesystem), never internal collaborators. Refactor only on green. Do NOT create a new branch.

(Optional alternative: write those standing rules to `$WORKTREE/AGENTS.md` before the run — both `cursor-agent` and `codex` auto-read `AGENTS.md` at the workspace root — and keep the prompt to the actionable task. Inlining is the simpler, self-contained default.)

*Under the hood* (what the script runs — for maintainers; the orchestrator never types these):
- **cursor:** `cursor-agent -p --force --trust --workspace W [--model M] --output-format json` with the prompt on stdin; fix adds `--resume <id>` (or `--continue`). Receipt = `.result`, session = `.session_id`; `STATUS=ok` iff exit 0 **and** `.is_error == false`.
- **codex:** `codex exec --dangerously-bypass-approvals-and-sandbox --cd W --output-last-message R [--model M]` with the prompt on stdin; fix = `codex exec resume --last|<id> … ` run from `W` (resume takes no `--cd`). Receipt = the `R` file; `STATUS=ok` iff exit 0 and `R` non-empty.

## Phase 4 — REVIEW (loop, no cap)

- **Invoke `/thermo-nuclear-code-quality-review`** (Skill tool) against the PR/MR branch diff. You orchestrate; it runs its full rubric.
- Apply its bar: code-judo simplifications, the ~1000-line file smell, no scattered special-case branching, abstractions earning their keep, logic in the canonical layer. Prefer few high-conviction findings over many cosmetic nits.
- **Post findings as inline review comments** on the diff (GitHub) or **MR discussions** (GitLab) and **capture each comment/discussion ID** — exact commands in `../setup-yaah/scm-commands.md`. Add a one-line status comment on the PRD linking the PR/MR. Then set verdict:
  - **approved** — no presumptive blockers remain → Phase 5.
  - **changes-requested** — re-run the **configured implementer** with the fix prompt below, passing the comment IDs (claude: a new Agent call; cursor: `--resume` the saved session — see *Engine dispatch (fix round)* after the template). It works in the **same `$WORKTREE` / `$BRANCH`** and **replies on each comment thread** (`gh api …/replies` / `glab api …/discussions/{id}/notes`). Then re-run this phase, `round += 1`.
- **No cap.** Repeat until approved. Do not escalate to the user; do not give up on ordinary findings.

### Subagent fix prompt (template)

```
Address this code review on PR/MR #<M> (branch <$BRANCH>, worktree <$WORKTREE>) for PRD #<P>.
Tracker CLI: <CLI>.  Use /tdd: add/adjust tests for any behavior change; keep red → green → refactor.
Review fixes are normal commits on <$BRANCH> (the one-commit-per-child rule governs the
initial build, not review fixes); when a fix maps cleanly to one child, reference it in the
commit body. Do NOT create a new branch.

Findings to resolve (each with its comment/discussion id):
<paste the review findings + comment IDs>

Do this:
1. Work in the EXISTING worktree <$WORKTREE> on <$BRANCH>. Do not create a new branch.
2. Re-run the configured checks for what you touched.
3. Reply on each comment thread you resolved:
   gh:   gh api repos/{owner}/{repo}/pulls/<M>/comments/<id>/replies -f body="…how fixed"
   glab: glab api -X POST "projects/:id/merge_requests/<M>/discussions/<id>/notes" -f body="…how fixed"
4. Push. Return ONLY:
   checks:   <commands + pass/fail>
   resolved: <finding → what changed>
   open:     <anything you intentionally did not change, with why>
```

**Engine dispatch (fix round).** Same engines as Phase 3's **Implementer engines**, resuming context:
- `claude`: a fresh Agent call (`general-purpose`), prompt = the fix prompt above. (Pass the build summary in the prompt — a new subagent has no memory of the build.)
- `cursor` / `codex`: write the fix prompt to a `.md` file and re-run the script with `--mode fix` —
  ```
  bash <forge-skill-dir>/scripts/forge-implement.sh \
    --engine "$ENGINE" --workspace "$WORKTREE" --prompt-file "$FIX_PROMPT_FILE" --mode fix \
    [--session "$SESSION"] [--model "$MODEL"]
  ```
  cursor passes `--session "$SESSION"` (saved from the build) to keep full context; codex omits it (resumes via `--last`). Read the same tail block; gate on `STATUS=ok`. The per-thread replies (step 3) are ordinary `gh`/`glab` commands the agent runs autonomously inside the run.

## Phase 5 — RECAP

Print, in this order:
1. **Decisions** — locked requirements + doc files changed (CONTEXT.md / ADRs).
2. **Issue(s)** — number + URL, label.
3. **PR/MR(s)** — number + URL, branch, worktree path.
4. **Review** — rounds taken, final verdict, any findings deliberately left open (with why).
5. **Checks** — what ran and passed; flag anything not green.
6. **Next** — lead into the merge checkpoint **only if** the reviewer approved and all required checks are green. If any check is red, do NOT offer merge — loop back to Phase 4 with a fix round.

## Phase 6 — MERGE (the one gate)

- Gate condition: reviewer approved AND every required check green. Never present merge otherwise.
- Ask the user to approve merging `$BRANCH` to the default branch (the only approval forge asks for besides grilling).
- **On approval — sync the branch onto the latest default branch, re-verify, THEN merge** (all steps autonomous; the approval was the only user gate). Work in `$WORKTREE` on `$BRANCH`:
  1. `git fetch origin <default-branch>`. If `$BRANCH` already contains its tip (no new base changes), skip to step 5.
  2. **Rebase, do not merge:** `git rebase origin/<default-branch>`. This replays the PR/MR's commits on top of the latest base so no concurrent base change is discarded and no merge commit is introduced. A conflict you cannot resolve cleanly and correctly is a **hard blocker** — surface it and stop (do not force a resolution).
  3. If `config.tools.graphify` is true (or the legacy top-level `graphify: true`), run `graphify update .` from the worktree root and stage + commit any graph change (Conventional Commit). If graphify is unavailable, note it in the recap rather than failing. (Skip this step entirely when graphify is off.)
  4. `git push --force-with-lease` (the rebase rewrote history, so a plain push is rejected; `--force-with-lease` refuses to clobber if someone else pushed to the PR/MR meanwhile — if rejected, re-fetch and reconcile, never plain `--force`).
  5. **Re-run the Phase 4 review loop once as verification.** The rebase merged new base code into the diff's context, so re-review to confirm nothing broke. If it requests changes, run normal no-cap fix rounds (fix subagent on the same branch); after any code change re-run graphify (if enabled) + commit + push. Loop until the reviewer approves again.
  6. Merge the single PR/MR via the tracker CLI (`gh pr merge` / `glab mr merge`, per repo convention). Its `Closes` refs auto-close the PRD parent and every child issue on merge — confirm they closed; if the tracker did not auto-close one, close it by hand referencing the merge commit.
  7. `cd` back to the main repo clone (you cannot remove a worktree that is your cwd), then `git checkout <default-branch> && git pull` so the main clone reflects the merge.
  8. Tear the worktree down: `bash <forge-skill-dir>/scripts/forge-worktree.sh remove "$WORKTREE"` (it removes the worktree, deletes the `feat/*` branch, and prints `REMOVED=<path>`).

## Edge cases

- **No `.yaah/config.yml`:** invoke `/setup-yaah` to create it, then proceed (not a hard blocker — it's first-run setup).
- **No git remote / CLI not authed:** hard blocker (Phase 0 or 2) — surface and stop.
- **Worktree script fails:** hard blocker — do not fall back to working on the base branch.
- **Trivial / one-liner work:** still run the full chain (issue + subagent PR/MR + review) — do NOT ask the user to skip it. The two-checkpoint contract and the PR/issue link must survive even for small changes.
- **Subagent can't get a check to green:** it reports `open:` with the reason; you re-spawn with tightened guidance. A failed check is never on its own a hard blocker — the loop has no cap. Only a genuinely unrecoverable failure stops the run, and a red check NEVER reaches the merge gate (Phase 5/6 keep looping).
- **CLI engine missing or unauthed (engine=cursor|codex):** hard blocker at Phase 0 preflight — surface the right install/auth hint and stop. cursor: `curl https://cursor.com/install -fsS | bash` / `export CURSOR_API_KEY=…` or `cursor-agent login`. codex: `npm i -g @openai/codex` / `codex login` or `OPENAI_API_KEY`. Do NOT silently fall back to the claude engine — the user chose this engine.
- **CLI engine run hangs or times out:** the timeout wrapper kills it; treat that round as failed and re-run (same as a failed check — no cap). Only a run that hangs on *every* retry, or exits non-zero with an unrecoverable error, stops the run.
- **Invalid model:** the CLI exits non-zero. Leave `implementer.model` blank to use the engine's default, or list valid names — cursor: `cursor-agent --list-models`; codex: `~/.codex/config.toml` `model =` or `-m`. Note model names are engine-specific (a cursor model id like `composer-2.5` is NOT a valid codex model and vice-versa) — reset `model` when switching engines.
- **User interrupts mid-run:** keep the state block current so the run resumes from the last completed phase; the worktree persists.
- **Many child issues from Phase 2:** they are **commits in ONE PR**, not separate PRs — one worktree, one branch, one PR/MR, one `round` counter, and one merge gate for the whole PRD. Implement them in dependency order, one commit each. If a later child depends on an earlier child's code, that is fine — it is already on the same branch.
- **A child issue turns out unbuildable / should be dropped mid-build:** leave its PRD box unchecked, do NOT put its `Closes #<child>` in the PR body (so the merge won't auto-close it), note it in the receipt + recap, and keep going with the rest. Never block the whole PRD on one child — surface it at recap.
- **`to-prd` or `to-issues` tries to quiz the user:** it must not — Phase 1 locked everything. Feed it the grilled `CONTEXT.md`/ADRs and the locked-requirements summary so it decides autonomously; only a true hard blocker stops the run.
