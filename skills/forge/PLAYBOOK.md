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

**One PRD ⇒ one PR.** Unlike the old per-slice model, every child issue is implemented as a single commit on a **single branch / single PR** (Phase 3), and the whole PRD has **one merge gate** (Phase 6). `worktree`, `branch`, `pr`, and `round` are per PRD, not per child. Each **child** issue is closed by the implementer the moment its commit lands (Phase 3, step 2g) — don't wait for the merge, because a `Closes #` ref only fires once the branch reaches the default branch. The **PRD parent** is the exception: leave it open and let the Phase 6 merge auto-close it via the PR/MR's `Closes #<prd>` ref. Keep the PRD task-list current as each child closes.

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
   g. CLOSE this child issue NOW — do NOT wait for the merge. The "Closes #<child>" in the
      commit/PR body only fires when the branch reaches the default branch (Phase 6 merge),
      so close it explicitly the moment its commit lands so progress is visible in the tracker:
        gh:   gh issue close <child> --reason completed
        glab: glab issue close <child>
      (Leave the PRD parent #<P> OPEN — the merge's "Closes #<P>" closes it at the end.)
3. The single PR/MR (opened at the first commit) Closes the PRD AND every child issue:
     gh:   gh pr create --base <DEFAULT_BRANCH> --head <$BRANCH> --title T \
             --body $'Closes #<P>\nCloses #<a>\nCloses #<b>\nCloses #<c>'
     glab: glab mr create --source-branch <$BRANCH> --target-branch <DEFAULT_BRANCH> --title T \
             --description $'Closes #<P>\nCloses #<a>\nCloses #<b>\nCloses #<c>'
4. Return ONLY this receipt (no prose):
   branch:  <name>
   pr:      #<M> <url>
   prd:     #<P> — boxes checked: <a,b,c>
   closed:  <child issues closed as their commits landed: a,b,c>
   commits: <one line per child: #<child> → <sha>>
   checks:  <each command run + pass/fail>
   summary: <2–4 lines: what you built and any caveat>
```

### Implementer engines

The build prompt above and the fix prompt in Phase 4 are **engine-agnostic** — the same text runs under any engine. `implementer.engine` is `claude` (default), `cursor`, or `codex`. `implementer.model` optionally overrides the model: for **claude** it is an Agent-tool alias (`sonnet`/`opus`/`haiku`, blank = inherit the session model); for **cursor/codex** it is that engine's own id. Two further keys, `implementer.agent` (default `general-purpose`) and `implementer.workflow` (default `false`), apply to the **claude** engine only. A missing block ⇒ `claude` / `general-purpose` / `workflow:false`. Receipt format and success contract are identical across engines; only *how* the prompt is delivered differs.

#### `claude` (default) — a Claude Code subagent

Invoke the subagent via the Agent tool, **honoring the config**:
- `subagent_type` = `implementer.agent` (default `general-purpose`). It needs Bash + the tracker CLI + edit tools; a read-only type (e.g. `Explore`) cannot commit/close issues — if `implementer.agent` lacks those tools, that is a hard blocker, surface it.
- `model` = `implementer.model` when set (an alias: `sonnet`/`opus`/`haiku`); **omit the param when blank** so the subagent inherits the session model. Pass the same model on every build and fix call.
- `cwd` = `$WORKTREE`; `prompt` = the build prompt (Phase 3) or the fix prompt (Phase 4). The subagent's final message **is** the receipt.

**Sequential (`implementer.workflow: false`, the default).** Spawn exactly **one** subagent with the build prompt; it works the children one-by-one as the build contract describes. Fix rounds (Phase 4) are a fresh Agent call with the fix prompt.

**Parallel (`implementer.workflow: true`) — branch-per-issue via the Workflow tool.** Setting this `true` is the user's opt-in for forge to run a workflow. This is the **only** mode that changes forge's git topology: `$BRANCH` (cut in Phase 0 off the default branch) becomes the **PRD integration branch**; each child issue gets its **own issue branch + own worktree + own PR into the PRD branch**; and the single user gate is still the Phase 6 merge of the PRD branch into the default branch. Children are **built in parallel** on their own branches; their PRs are then **squash-merged into `$BRANCH` one at a time** (a serial merge barrier — see below — because GitHub won't lock an unprotected branch against concurrent merges). (Real branches + PRs, so no cherry-pick / detached-HEAD / worktree-bookkeeping: the Workflow tool's `isolation:'worktree'` gives each agent its own checkout and auto-cleans it, and every commit lives on the pushed issue branch, then on `$BRANCH` after merge.)

```
default
  └─ $BRANCH  (PRD integration branch — pushed to origin early)
       ├─ $BRANCH--issue-<a>  ─PR(Closes #a)─┐
       ├─ $BRANCH--issue-<b>  ─PR(Closes #b)─┤ built in PARALLEL; PRs
       └─ $BRANCH--issue-<c>  ─PR(Closes #c)─┘ then squash-merged ONE AT A TIME ▶ $BRANCH
  ◀── Phase 6: ONE PR  $BRANCH → default   (the only user gate; body `Closes #<prd>`)
```

Split the work: **build in parallel, merge serially.** The expensive part (TDD + checks per child) fans out; the cheap-but-shared part (merging into `$BRANCH`, closing issues, editing the PRD body) is serialized so nothing races.

- **PRD integration branch.** Push `$BRANCH` to origin first (`git push -u origin $BRANCH`) so issue-PRs can target it. **Open the Phase 6 gate PR (`$BRANCH → default`, body `Closes #<prd>` only — the children get closed by hand, so don't list them) once the first child has merged into `$BRANCH`** (a PR on an empty `$BRANCH` errors with "no commits between"). The orchestrator opens it — never a build agent. It is the only user approval and is unchanged; record it as state `pr`.
- **Issue branch names derive from `$BRANCH`.** `$BRANCH` is `feat/<slug>-<unique>` (from `forge-worktree.sh`); name each child branch `${BRANCH}--issue-<child>` (double-dash suffix — NOT `${BRANCH}/<child>`, which is an invalid nested ref because `$BRANCH` already exists). There is no separate `<prd>` token in the branch name.
- **Dependency layers, not a free-for-all.** Group the children into topological layers from the Phase 2 dependency order: a layer holds children that are mutually independent; each branches off the **current `origin/$BRANCH` tip**, and a dependent child waits until its blockers have **merged and pushed** to `origin/$BRANCH` (so its branch already contains their code). The merge barrier (below) confirms a layer's merges are pushed before the next layer's agents fan out. **Only parallelize children you know are independent — unclear DAG ⇒ one child per layer (fully sequential). Never run a child alongside its blocker.**
- **Build agents (fan-out, per layer)** — one `agent()` per child, `isolation: 'worktree'`, `agentType: <implementer.agent>`, `model: <implementer.model or omit>`. Each agent, in its own isolated worktree, does the heavy lifting only:
  1. `git fetch origin` and create its issue branch off the latest PRD tip: `git checkout -b ${BRANCH}--issue-<child> origin/$BRANCH`. (A brand-new branch — no "already checked out in another worktree" clash; that only bites `$BRANCH` itself, so **agents never check out `$BRANCH` directly**.)
  2. Run the build contract's TDD loop for its **single** child; run the configured checks (all green).
  3. Commit, **push the issue branch**, open a PR **into `$BRANCH`** (`--base $BRANCH`, body `Closes #<child>`).
  4. Return `{child, prNumber, branch, checks}`. It does **NOT** merge, close the issue, or touch the PRD body — all shared-state writes belong to the merge barrier.
- **Merge barrier (serialized, per layer) — this is the correctness keystone.** GitHub does **not** lock an unprotected `$BRANCH`, so two `gh pr merge` calls firing at once can both "succeed" against a stale base and silently lose an update. So a **single** step (one `agent()`, or the orchestrator) merges the layer's PRs **one at a time, in dependency order**. For each child PR: ensure it's up to date with the freshly-fetched `origin/$BRANCH` tip (if behind, rebase the issue branch onto it, re-run checks, push) → **squash-merge** (`gh pr merge --squash --delete-branch`) → **close the issue** (`gh issue close <child> --reason completed`) → **backlink the PR URL** (the *URL*, not a SHA — the Phase 6 rebase rewrites `$BRANCH` SHAs, so a SHA backlink would dangle) → **flip that child's PRD box** by re-reading the PRD body fresh and writing it back. Because every merge, close, and PRD-body edit happens in this one serial lane, there is no lost-update, no conflicting concurrent merge, and no clobbered PRD task-list. After the layer, confirm its merges are on `origin/$BRANCH` before launching the next layer.
- **Conflicts are resolved, not dropped.** A textual conflict during the barrier's rebase is resolved (the barrier has both sides) and re-merged. Only a child whose **checks can't go green** is unbuildable: leave its box unchecked, do not close it, note it. A failed/`null` build agent **and any children that depend on it** are deferred — retry the blocker (no cap) and only run its dependents once it has merged; never launch a dependent whose blocker never landed.
- **Fix rounds stay sequential.** Phase 4 reviews the aggregate `$BRANCH → default` diff and runs fixes as a **single** subagent on `$BRANCH` (configured `agent`/`model`) — not a fan-out. Internal issue-PRs are not separately reviewed; fix-round commits land directly on `$BRANCH` and do not reopen the already-closed child issues.
- **GitLab (`cli: glab`):** identical shape — the issue branch's MR targets `$BRANCH` (`glab mr create --target-branch $BRANCH --source-branch ${BRANCH}--issue-<child> --description 'Closes #<child>'`), squash-merge with `glab mr merge --squash --remove-source-branch`, close with `glab issue close <child>`. The `$BRANCH → default` MR is the user gate. Map every `gh` above to its `glab` form per `setup-yaah/scm-commands.md`.

Skeleton (the orchestrator authors the actual script; `LAYERS` is the topological grouping above — an undeterminable DAG ⇒ `[[a],[b],[c]]`, one child per layer. Build fans out; the merge barrier serializes all shared writes):
```js
export const meta = { name: 'forge-build', description: 'Build PRD children on per-issue branches in parallel, merge each into the PRD branch serially', phases: [{title:'Build'},{title:'Merge'}] }
const merged = []
for (const layer of args.LAYERS) {                 // layers sequential; children within a layer parallel
  const built = await parallel(layer.map(child => () =>
    agent(buildPrompt(child), { phase:'Build', isolation:'worktree', agentType: args.agent || 'general-purpose', ...(args.model?{model:args.model}:{}), schema: BUILD_RECEIPT })
  ))
  const ok = built.filter(Boolean)                 // each ok child: own branch built + PR opened into $BRANCH
  // ONE serial barrier: rebase-if-behind → squash-merge → close issue → backlink PR URL → flip PRD box, per child in dep order
  const done = await agent(mergeBarrierPrompt(ok), { phase:'Merge', agentType: args.agent || 'general-purpose', ...(args.model?{model:args.model}:{}), schema: MERGE_RECEIPT })
  merged.push(...done.children)                    // failed/null build agents + their dependents are deferred (retry, no cap)
}
return assembleReceipt(merged)
```

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

*Prompt adaptation (cursor & codex).* Neither CLI has Claude Code skills, so in the prompt file replace the build contract's TDD directive (step 2a — "Invoke the /tdd skill…") — with this inline directive (the per-child loop, one-commit-per-child, task-list, backlink, and close-the-child steps stay verbatim):
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
- `claude`: a fresh Agent call using the configured `implementer.agent` (default `general-purpose`) and `implementer.model` (alias when set, else omit), prompt = the fix prompt above. (Pass the build summary in the prompt — a new subagent has no memory of the build.) Fix rounds are a **single** subagent on `$BRANCH` even when `implementer.workflow: true` — the workflow fan-out is for the initial build only.
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
  6. Merge the single PR/MR via the tracker CLI (`gh pr merge` / `glab mr merge`, per repo convention). The child issues were already closed in Phase 3 as their commits landed; the merge's `Closes #<prd>` ref now auto-closes the PRD parent — confirm the parent closed and every child is still closed; if the tracker left any open, close it by hand referencing the merge commit.
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
- **Invalid model:** for **claude**, `implementer.model` must be an Agent-tool alias — `sonnet`, `opus`, or `haiku` (NOT a cursor/codex id, NOT a full model string); anything else fails the Agent call, so leave it blank to inherit the session model. For **cursor/codex** an invalid id makes the CLI exit non-zero — leave blank for the engine's default, or list valid names (cursor: `cursor-agent --list-models`; codex: `~/.codex/config.toml` `model =` or `-m`). Model vocabularies are engine-specific (a cursor id like `composer-2.5` is not a valid codex or claude value) — reset `model` when switching engines.
- **User interrupts mid-run:** keep the state block current so the run resumes from the last completed phase; the worktree persists.
- **Many child issues from Phase 2:** in the default sequential build they are **commits in ONE PR**, not separate PRs — one worktree, one branch, one PR/MR, one `round` counter, and one merge gate for the whole PRD. Implement them in dependency order, one commit each. If a later child depends on an earlier child's code, that is fine — it is already on the same branch. (Under `implementer.workflow: true` each child rides its own internal issue-PR into the PRD integration branch, but there is still one `round` counter and one user merge gate — the `$BRANCH → default` PR; see "Parallel" under Implementer engines.)
- **A child issue turns out unbuildable / should be dropped mid-build:** leave its PRD box unchecked, do NOT close it (skip step 2g), and do NOT put its `Closes #<child>` in the PR body (so the merge won't auto-close it either), note it in the receipt + recap, and keep going with the rest. Never block the whole PRD on one child — surface it at recap.
- **`to-prd` or `to-issues` tries to quiz the user:** it must not — Phase 1 locked everything. Feed it the grilled `CONTEXT.md`/ADRs and the locked-requirements summary so it decides autonomously; only a true hard blocker stops the run.
- **Parallel build (`implementer.workflow: true`, claude only):** `$BRANCH` is a PRD integration branch; children are **built in parallel** on their own issue branches + worktrees, and their PRs are **squash-merged into `$BRANCH` one at a time by a serial merge barrier** (GitHub won't lock an unprotected branch, so concurrent merges would lose updates). The final state is identical to the sequential build — one commit per child on `$BRANCH`, one user-gate PR (`$BRANCH → default`), each issue closed by hand, each box checked. A build agent that fails its child drops to `null` (filter it out); retry it — and **defer any children that depend on it** until it lands — no cap. A merge conflict is **resolved by the barrier rebasing the issue branch** (a built+tested child is never dropped for a textual conflict); only a child whose checks can't go green is unbuildable (box unchecked, not closed, noted) — never block the PRD. If the dependency DAG can't be determined, do NOT guess independence — one child per layer (equivalent to `workflow:false`). The workflow is the **build** only; grilling, PRD/issues, review, and merge are unchanged.
