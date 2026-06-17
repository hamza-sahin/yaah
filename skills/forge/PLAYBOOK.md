# forge — Playbook

Per-phase mechanics, the subagent prompt templates, and edge cases. SKILL.md is the spine; this is the detail. Read once at the start of a run. Tracker commands (`gh` vs `glab`) come from `.yaah/config.yml` → `cli`; full recipes for both are in [../setup-yaah/scm-commands.md](../setup-yaah/scm-commands.md).

## Phase 0 — CONFIG + WORKTREE (isolation)

- **Read `.yaah/config.yml`** at the repo root. If it is missing, invoke `/setup-yaah` to create it, then continue with `cli`, `checks`, `default_branch`, and `issue_label` from it. (The `tools.*` flags — `graphify`/`rtk`/`caveman` — only record what `/setup-yaah` wired; forge **always** uses all three and never reads them as a gate, so you don't branch on them here.)
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

3. **Self-review the published artifacts (non-interactive, INLINE).** After `to-issues` publishes, before Phase 3, the orchestrator re-reads the PRD + child issues and fixes defects **by editing them in place** (`gh issue edit` / `glab issue update`) — no subagent, no user prompt. Do it **inline, not as an Agent call**: a fresh reviewer subagent on a plan/spec costs ~25 min for no measurable quality gain, while a ~30s inline scan catches the real bugs. Check:
   - **(a) Coverage** — every PRD user story maps to ≥1 child issue. A story with no child ⇒ add the child.
   - **(b) DAG validity** — every child's `Blocked by` references a real sibling, there are no cycles, and the dependency order matches publish order. (Order itself is already `to-issues`' job — here you only validate cycles/dangling refs.)
   - **(c) No placeholders** — reject and rewrite any of: `TBD`/`TODO`/"decide during build"; acceptance criteria like "handle edge cases"/"add validation"/"appropriate error handling"; "Write tests for the above" with no behavior named; "similar to issue N"; a step that says *what* without *how*.
   - **(d) Interface consistency** — every interface a PRD Implementation Decision names is built by some child; no child consumes a signature no sibling produces.
   - **(e) Glossary/ADR consistency** — PRD and issue titles use `CONTEXT.md` terms and contradict no ADR.

   Fix every finding inline. The ONLY escape is a genuine internal contradiction the orchestrator cannot resolve from `CONTEXT.md`/ADRs — that is a hard blocker (surface and stop); never bail to the user for anything you can fix by editing an issue.

4. **Derive the shared-contract blocks (record in state, inject at prompt-assembly — do NOT edit the issues).** Two artifacts the build and review prompts carry so independently-built work doesn't diverge on shared contracts:
   - **Global Constraints** — the binding rules every child must obey, copied **verbatim** from the grilled `CONTEXT.md`/ADRs + PRD: version floors, naming conventions, exact values/formats, error/handling conventions, stated relationships between components. This is the reviewer's attention lens too.
   - **Per-child Interfaces** — for each child, what it **consumes** and **produces** (exact function/type/endpoint signatures it depends on or exposes), derived from the PRD's Implementation Decisions + the dependency DAG.
   These are **most critical under `implementer.workflow: true`** — each parallel child sees only its own issue ("do NOT restate sibling bodies"), so without the blocks two children guess a shared signature differently and pass the merge-barrier rebase (textually clean) while being semantically incompatible. They also help the sequential build keep cross-child interfaces consistent. Generate them from the already-locked artifacts — never fork or edit `to-prd`/`to-issues`, and never invent a constraint the user didn't lock.

**One PRD ⇒ one PR.** Unlike the old per-slice model, every child issue is implemented as a single commit on a **single branch / single PR** (Phase 3), and the whole PRD has **one merge gate** (Phase 6). `worktree`, `branch`, `pr`, and `round` are per PRD, not per child. Each **child** issue is closed by the implementer the moment its commit lands (Phase 3, step 2g) — don't wait for the merge, because a `Closes #` ref only fires once the branch reaches the default branch. The **PRD parent** is the exception: leave it open and let the Phase 6 merge auto-close it via the PR/MR's `Closes #<prd>` ref. Keep the PRD task-list current as each child closes.

## Phase 3 — BUILD (handoff → implementer → tdd)

1. Call the Skill tool with `handoff`, scoped to "prompt a fresh agent to implement the PRD's child issues one-by-one via TDD inside `$WORKTREE`." The doc **references the PRD + every child issue by URL** (in dependency order) + the grilled decisions/doc changes — it does not restate the issue bodies.
2. Deliver the build prompt to the **configured implementer engine** (`implementer.engine`, default `claude`) — exact mechanics in **Implementer engines** below. The prompt = the handoff doc + the build contract below, with `<CHECKS>`, `<SMOKE>`, and `<CLI>` filled from config, `<GLOBALS>`/`<INTERFACES>` from the Phase 2 shared-contract blocks (and the `/tdd` line adapted per engine). For a CLI engine (`cursor`/`codex`) write that prompt to a `.md` file and run `forge-implement.sh` — **never hand-build the CLI command**.
3. Read the returned receipt and **react to its typed `status:` line** — do NOT reflex-respawn with the same prompt regardless of why it stopped:
   - **DONE** → write `pr` (and, for cursor, the session id) into state; proceed to Phase 4.
   - **DONE_WITH_CONCERNS** → read the concerns; address any correctness/scope issue (a fresh fix dispatch) BEFORE Phase 4; carry the rest into the Phase 5 recap. Then proceed.
   - **NEEDS_CONTEXT** → supply exactly the missing input named under `needs:` (fetch the issue, resolve the interface from CONTEXT.md/ADRs, etc.) and re-dispatch with it added. Do NOT ask the user — derive it from the locked artifacts; only a true unresolvable contradiction is a hard blocker.
   - **BLOCKED** → assess the named `blocked:` cause and pick the matching response, not a blind retry: a too-big child → split it into smaller commits and re-dispatch; a wrong model for the task → escalate `implementer.model`; a check that won't go green → it should already have run /systematic-debugging, so re-dispatch with the root-cause findings in the prompt; a genuine architectural problem (3+ fixes failed) → that is the rare hard blocker — surface it and stop.
   - **`tdd:` line** → if it shows RED was not observed for a behavior, treat it like a DONE_WITH_CONCERNS: re-dispatch to add the missing test-first coverage before review (green checks alone don't prove tests were written first; the build squashes red+green into one commit, so this line is the only RED signal).
   - A **missing PR/MR** when status claims DONE is a hard blocker.
   **Stateful re-spawn ledger (no cap, but never stateless).** Every re-dispatch (build retry or BLOCKED follow-up) carries forward: the attempt number for that failure, and a 1–3 line summary of what the previous attempt tried and why it failed. A fresh subagent has no memory of the build, so without this the "3+ fixes → question architecture" escalation can never fire. Keep a per-failing-check attempt counter in state; at 3 consecutive failures on the SAME check, the next dispatch's ONLY job is a /systematic-debugging investigation (find + report root cause) before any further fix.

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
Smoke to run: <SMOKE>         (after ALL children; proves the artifact RUNS; empty = skip)
Global constraints (VERBATIM, binding on every child): <GLOBALS>   (version floors, naming, exact values/formats, component relationships — obey exactly)
Interfaces (what each child consumes / produces): <INTERFACES>    (use these exact signatures across children; do not invent your own)
Locked decisions / handoff: <paste the handoff doc>

Efficiency tools — use them throughout (they cut tokens; if a tool is genuinely
absent, fall back and keep going — never block on it):
- Explore with graphify, not raw grep / whole-file reads:
  `graphify query "<question>"`, `graphify explain "<concept>"`, `graphify path "<A>" "<B>"`.
- Run shell through rtk — prefix commands: `rtk git status`, `rtk grep …`, `rtk ls …`,
  `rtk wc …` — for token-lean output.
- Keep your own progress/status notes terse (caveman register): drop articles and filler.
  Write CODE, COMMIT messages, PR/MR bodies, and any SECURITY note in NORMAL prose.

Do this:
1. cd into the worktree and confirm you are on <$BRANCH> (git rev-parse --abbrev-ref HEAD).
2. Work the child issues IN THE GIVEN ORDER. For EACH child:
   a. Invoke the /tdd skill and follow it strictly: red → green → refactor, one behavior
      at a time, vertical tracer bullets, behavior tested through public interfaces
      (see tdd/tests.md, tdd/mocking.md). Iron Law: no production code without a failing
      test first — RUN each test and WATCH it fail for the right reason (behavior missing,
      not a typo) before writing impl, then re-run and watch it pass with nothing else
      broken; any code written before its failing test gets deleted and rewritten.
      Requirements are LOCKED (PRD/issues/CONTEXT.md/ADRs) — do /tdd's planning from those
      and do NOT seek user approval (the locked requirements ARE the approval).
      Do NOT create a new branch.
   b. Run the configured checks for what you touched (the <CHECKS> list, in order). All must pass.
      If a check FAILS: do NOT guess-and-retry. Invoke the /systematic-debugging skill and follow
      it — read the error, reproduce, trace the bad value to its source, form ONE hypothesis, make
      the smallest fix, re-run. A failing check is a signal, not noise; re-running the same change
      is not a fix. If you've tried 3+ fixes for the SAME failure, STOP and return status=BLOCKED
      with the root-cause/architectural concern (see the receipt) instead of looping.
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
2h. After ALL children are committed, run <SMOKE> (if non-empty) to confirm the artifact actually
    runs — not just that tests pass. A smoke failure is treated exactly like a failed check:
    /systematic-debugging, fix, re-run (no cap). For a bug-fix PRD, also confirm the original
    symptom now fails to reproduce (a test that reproduced it, now green).
3. The single PR/MR (opened at the first commit) Closes the PRD AND every child issue:
     gh:   gh pr create --base <DEFAULT_BRANCH> --head <$BRANCH> --title T \
             --body $'Closes #<P>\nCloses #<a>\nCloses #<b>\nCloses #<c>'
     glab: glab mr create --source-branch <$BRANCH> --target-branch <DEFAULT_BRANCH> --title T \
             --description $'Closes #<P>\nCloses #<a>\nCloses #<b>\nCloses #<c>'
4. Return ONLY this receipt (no prose). The FIRST line is a typed status:
   status:  DONE | DONE_WITH_CONCERNS | BLOCKED | NEEDS_CONTEXT
            DONE = every child built, all checks green, PR open.
            DONE_WITH_CONCERNS = built + green, but with caveats the orchestrator must read
              (a deviation from a decision, a fragile area, a deferred-but-noted item).
            BLOCKED = could not finish (a check you cannot get green after systematic-debugging
              + 3 fixes, or a root-cause/architectural problem) — name it under `blocked:`.
            NEEDS_CONTEXT = missing an input you need to proceed (an unreachable issue, an
              undefined interface, a contradictory requirement) — name it under `needs:`.
   tdd:     <per child: RED observed (test run, failed for the right reason) + GREEN observed
            (re-run, passes, nothing else broke). If you did NOT verify RED for a behavior, say so.>
   branch:  <name>
   pr:      #<M> <url>
   prd:     #<P> — boxes checked: <a,b,c>
   closed:  <child issues closed as their commits landed: a,b,c>
   commits: <one line per child: #<child> → <sha>>
   checks:  <each command run + pass/fail>
   smoke:   <each smoke command run + pass/fail, or "none configured">
   blocked: <only if status=BLOCKED: what's red + the root cause you found + why you stopped>
   needs:   <only if status=NEEDS_CONTEXT: exactly what's missing>
   summary: <2–4 lines: what you built and any caveat>
```

### Implementer engines

The build prompt above and the fix prompt in Phase 4 are **engine-agnostic** — the same text runs under any engine. `implementer.engine` is `claude` (default), `cursor`, or `codex`. `implementer.model` optionally overrides the model: for **claude** it is an Agent-tool alias (`sonnet`/`opus`/`haiku`, blank = inherit the session model); for **cursor/codex** it is that engine's own id. `implementer.agent` (default `general-purpose`) applies to the **claude** engine only; `implementer.workflow` (default `false`) applies to **all engines** (claude fans out via the Workflow tool, cursor/codex via orchestrator-launched background `forge-implement.sh` processes). A missing block ⇒ `claude` / `general-purpose` / `workflow:false`. Receipt format and success contract are identical across engines; only *how* the prompt is delivered differs.

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
- **Build agents (fan-out, per layer)** — one `agent()` per child, `isolation: 'worktree'`, `agentType: <implementer.agent>`, `model: <implementer.model or omit>`. Each agent's prompt carries the **same efficiency-tools directive** as the build template (graphify-first exploration, `rtk`-prefixed shell, terse working output) **plus the Global Constraints block verbatim and that child's Interfaces block** (Phase 2 step 4) — this is what keeps parallel children, which never see each other's issues, from diverging on a shared signature. Each agent, in its own isolated worktree, does the heavy lifting only:
  1. `git fetch origin` and create its issue branch off the latest PRD tip: `git checkout -b ${BRANCH}--issue-<child> origin/$BRANCH`. (A brand-new branch — no "already checked out in another worktree" clash; that only bites `$BRANCH` itself, so **agents never check out `$BRANCH` directly**.)
  2. Run the build contract's TDD loop for its **single** child; run the configured checks (all green).
  3. Commit, **push the issue branch**, open a PR **into `$BRANCH`** (`--base $BRANCH`, body `Closes #<child>`).
  4. Return `{status, child, prNumber, branch, checks, tdd}` — `status` is the typed build status (DONE / DONE_WITH_CONCERNS / BLOCKED / NEEDS_CONTEXT) for THIS child, `tdd` certifies RED-then-GREEN was observed. It does **NOT** merge, close the issue, or touch the PRD body — all shared-state writes belong to the merge barrier. A non-DONE child is handled per the typed-status reactions in Phase 3 step 3 (a BLOCKED child and its dependents are deferred/retried with the ledger, not blindly re-run).
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

This is the **`workflow:false`** path: one CLI agent works all children sequentially over the single `$BRANCH`. `workflow` is honored by every engine now — for `workflow:true` on a CLI engine, see *`cursor` / `codex` parallel* below.

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

*Prompt adaptation (cursor & codex).* Neither CLI has Claude Code skills, so in the prompt file replace the build contract's **TDD directive** (step 2a — "Invoke the /tdd skill…") and its **debugging directive** (step 2b — "Invoke the /systematic-debugging skill…") with these inline directives (the per-child loop, one-commit-per-child, task-list, backlink, and close-the-child steps stay verbatim):
> Work strictly test-first in **red → green → refactor** cycles, one behavior at a time. **Iron Law: no production code without a failing test first** — write the test, **RUN it, and watch it FAIL for the right reason** (the behavior is missing, not a typo/import/wrong-assertion) before writing any implementation; then **RUN it again and watch it PASS** with no other test broken. Any production code written before its failing test gets deleted and rewritten test-first. Build **vertical tracer bullets** (a thin slice through every layer), not horizontal layers. Test behavior through **public interfaces**, never implementation details; mock only true external boundaries (network, clock, filesystem), never internal collaborators. Refactor only on green. Requirements are already locked — plan from them, do NOT seek approval. Do NOT create a new branch.

> **When a check fails, debug — don't guess.** Find the root cause before any fix: read the full error/stack trace, reproduce it, check what your change touched, **trace the bad value back to its source** (fix at the source, not the symptom), state ONE hypothesis, make the **smallest** fix, then re-run. Never re-run the same change hoping it passes, and never stack multiple fixes at once. For an order-dependent test failure, bisect which test pollutes shared state. For a flaky timeout, wait on the actual condition, not an arbitrary sleep. If 3 fixes for the SAME failure haven't worked, STOP and report it as BLOCKED with the root cause — do not attempt fix #4.

(Optional alternative: write those standing rules to `$WORKTREE/AGENTS.md` before the run — both `cursor-agent` and `codex` auto-read `AGENTS.md` at the workspace root — and keep the prompt to the actionable task. Inlining is the simpler, self-contained default.)

*Efficiency tools matter most here.* cursor and codex run **outside** the global rtk / caveman / graphify hooks, so the prompt's efficiency-tools directive (graphify-first exploration, `rtk`-prefixed shell, terse working output) is the ONLY thing that gives the CLI builds those savings — keep it in the prompt file verbatim for both the build and the fix prompt (or fold the standing rules into `$WORKTREE/AGENTS.md`, which both CLIs auto-read). Never strip it when adapting the prompt.

*Under the hood* (what the script runs — for maintainers; the orchestrator never types these):
- **cursor:** `cursor-agent -p --force --trust --workspace W [--model M] --output-format json` with the prompt on stdin; fix adds `--resume <id>` (or `--continue`). Receipt = `.result`, session = `.session_id`; `STATUS=ok` iff exit 0 **and** `.is_error == false`.
- **codex:** `codex exec --dangerously-bypass-approvals-and-sandbox --cd W --output-last-message R [--model M]` with the prompt on stdin; fix = `codex exec resume --last|<id> … ` run from `W` (resume takes no `--cd`). Receipt = the `R` file; `STATUS=ok` iff exit 0 and `R` non-empty.

#### `cursor` / `codex` parallel (`implementer.workflow: true`) — orchestrator-driven background fan-out

`implementer.workflow` is **no longer claude-only**. With a CLI engine and `workflow: true`, forge runs the **same parallel topology** as the claude path (the diagram + git model under *`claude` … Parallel* above — `$BRANCH` is the PRD integration branch, one issue branch + worktree + PR per child, all squash-merged into `$BRANCH` by a serial merge barrier, the single user gate is the `$BRANCH → default` PR). The **only** difference is the fan-out engine: there is no Workflow tool and no claude subagent — **the orchestrator itself launches N background `forge-implement.sh` processes** (one per child) and runs the merge barrier directly. `forge-worktree.sh` and `forge-implement.sh` are unchanged; this is pure orchestration. (Undeterminable DAG ⇒ one child per layer = sequentially equivalent to `workflow:false`.)

1. **Per-child handoff — one `/handoff` per child** (N calls, NOT the single shared handoff the sequential CLI build uses). Scope each to that **one** child — its issue URL + the PRD URL for context + the grilled decisions/ADRs — and do NOT restate sibling issue bodies. Each background CLI agent is a separate process with zero ambient context working ONE child in ONE worktree, so: one handoff = one child = one worktree = one PR.
2. **Dependency layers — reuse the claude-parallel rule verbatim** (topological layers from the Phase 2 order; a layer is mutually-independent children; a dependent waits until its blockers have **merged + pushed to `origin/$BRANCH`**; **undeterminable DAG ⇒ one child per layer**, fully sequential; never run a child alongside its blocker). Layers run in sequence; children within a layer fan out.
3. **Push `$BRANCH` first** — `git push -u origin $BRANCH` so a child worktree's base-ref resolves to `origin/$BRANCH` (`forge-worktree.sh` dies if neither `origin/$BRANCH` nor a local `$BRANCH` exists). Before each **later** layer, `git fetch origin $BRANCH` (the explicit base-ref path does NOT auto-fetch) so its children branch off a tip that already contains the merged blockers.
4. **Per-child worktree** — for each child in the layer: `bash <forge-skill-dir>/scripts/forge-worktree.sh create issue-<child> $BRANCH`; parse `WORKTREE=`/`BRANCH=` and **record the child → (worktree, branch) map in state** (the orchestrator owns it — there is no Workflow `isolation:'worktree'` auto-management here). The branch is whatever the script printed (`feat/issue-<child>-<unique>`) — do NOT hand-construct `${BRANCH}--issue-<child>`; record the printed name.
5. **Per-child prompt file** (`mktemp "${TMPDIR:-/tmp}/forge-prompt-XXXXXX".md`), in order: (a) that child's per-child handoff; (b) a **single-child build contract** (the per-child loop from the claude-parallel build agent above — confirm on the child branch, run the inline-TDD loop for the ONE child, run the configured `<CHECKS>` green, land EXACTLY ONE commit whose body carries `Closes #<child>`, push the issue branch, open a PR **into `$BRANCH`** with `--base $BRANCH` and body `Closes #<child>`; it does **NOT** merge, close the issue, backlink, or touch the PRD body — every shared-state write is the barrier's); (c) the **inline `/tdd` AND `/systematic-debugging` directives verbatim** (both replacement blocks above — CLI engines can't call the skills); (d) the **efficiency-tools directive verbatim** (graphify-first, `rtk`-prefixed shell, terse output — the CLI runs outside the global hooks); (e) the **Global Constraints block verbatim + this child's Interfaces block** (Phase 2 step 4) — mandatory here, since each background CLI agent sees only its own child and would otherwise guess shared signatures. Fill `<CLI>`/`<CHECKS>`/`<SMOKE>` from config, `<GLOBALS>`/`<INTERFACES>` from Phase 2; the PR base is `$BRANCH`, never the default branch.
6. **Fan out (background)** — launch each child's `forge-implement.sh` as a **background** process:
   ```
   bash <forge-skill-dir>/scripts/forge-implement.sh \
     --engine "$ENGINE" --workspace "<child-worktree>" --prompt-file "<child-prompt.md>" \
     [--model "$MODEL"] [--timeout 3600]
   ```
   **Concurrency cap — small (default 2–3).** Each CLI agent is heavy (its own worktree + a full model context); a layer wider than the cap runs in cap-sized waves (still all merged afterward, in dep order). There is no Workflow scheduler here, so the orchestrator self-limits — lower the cap on a constrained machine. Wait for the wave to finish, then read each **tail block** (`===FORGE-IMPLEMENT===`) and gate on `STATUS=ok`; parse the child's PR number from `RECEIPT_FILE`. `STATUS=fail`/`EXIT≠0` ⇒ failed round (read `STDERR_LOG`); `EXIT=124` = timed out. **Do NOT save the cursor `SESSION`** — the per-child worktree is torn down after merge, so there is nothing to resume (see *Engine dispatch (fix round)* in Phase 4).
7. **Merge barrier — the same serial barrier described under *`claude` … Parallel* above, run by the orchestrator directly** (one child at a time, dependency order: rebase-if-behind on the freshly-fetched `origin/$BRANCH` + re-run checks + push → **squash-merge** into `$BRANCH` → **close the child issue** → **backlink the PR URL** (not a SHA — Phase 6 rewrites `$BRANCH` SHAs) → **flip that child's PRD box**, re-reading the PRD body fresh). **Open the `$BRANCH → default` gate PR once the first child has merged** (body `Closes #<prd>` only — children are closed by hand; record as state `pr`). Confirm a layer's merges are on `origin/$BRANCH` before launching the next layer. GitLab maps exactly as in the claude-parallel barrier (`glab mr merge --squash --remove-source-branch`, `glab issue close`, etc.).
8. **Teardown** — after a child's PR squash-merges (`--delete-branch` already removed the remote issue branch), `bash <forge-skill-dir>/scripts/forge-worktree.sh remove "<child-worktree>"` (this replaces the Workflow tool's auto-clean). Tear down every child worktree by end-of-run, merged or not. The orchestrator stays in the main `$WORKTREE` throughout, so removing a child worktree is always safe (never your cwd). Keep a child's worktree alive only as long as you may still need it for the barrier's rebase-if-behind.
9. **Failure / retry / defer (no cap)** — a `STATUS=fail`/timeout/can't-go-green child is retried with tightened guidance (a **fresh** build in its worktree, not a resume); **defer its dependents** until it has merged + pushed. A genuinely unbuildable child: leave its box unchecked, do NOT close it, omit `Closes #<child>` from the gate PR, note it in the receipt + recap — never block the whole PRD on one child.

## Phase 4 — REVIEW (loop, no cap)

**One combined reviewer per round, dispatched on a cheap/scaled model.** Each round dispatches a **single read-only review subagent** (the Agent tool — NOT an inline Skill call) that follows the vendored `/spec-and-quality-review` skill and returns, in **one pass over the branch diff, BOTH verdicts plus a ⚠️ can't-verify verdict**: spec compliance (missing/extra/misunderstood + correctness + security) AND focused code quality. One reviewer, one fix pass clears both. The **deep, ambitious maintainability audit** (`/thermo-nuclear-code-quality-review` — code-judo, the ~1000-line smell, spaghetti-growth) runs **once at the final gate** (Phase 6), not every round — that is where the heavy pass is worth its cost. **Merge is gated on the combined per-round reviewer approving every round AND the final Phase-6 pass approving once.**

Why dispatched, not inline: a dispatched reviewer keeps the orchestrator's context lean (only the verdict + findings return — the diff never enters your context) and lets you **name the model** per call (an omitted model silently inherits the session's most expensive tier). The orchestrator coordinates and adjudicates; it does not read the diff itself.

- **Dispatch the reviewer.** One Agent call, `subagent_type: general-purpose` (or any read-capable type), **`model` = `review.model` from config — when blank, omit the param so it inherits the session model** (never force an expensive tier). cwd = `$WORKTREE`. The prompt tells it to **follow the `/spec-and-quality-review` skill**, reviewing the **`origin/<default>..$BRANCH` diff** (it self-derives the diff with git — forge never pastes a diff), and hands it: the **PRD + each child issue's acceptance criteria** as the requirements, **plus the Phase 2 Global Constraints block verbatim as its attention lens** (binding rules to check against — copy them, never a "don't flag" instruction). Its final message IS the review report (both verdicts + findings with file:line + any ⚠️ items). A requirement that lives in code the diff does **not** touch comes back as a **⚠️ can't-verify-from-diff** item — the orchestrator resolves each itself (you hold the PRD + cross-child context the reviewer lacks): convert a confirmed gap into an explicit fix-task, otherwise a Phase 5 recap note; **never turn it into a user question** (that would add a third touchpoint).
- **The reviewer is read-only; the orchestrator never softens it.** The review subagent reports findings only — it must **not** edit, commit, stage, or `git checkout` anything on `$BRANCH` (a mutated worktree would corrupt the Phase 6 rebase + `--force-with-lease`); all fixes route through the implementer. The orchestrator NEVER instructs the reviewer to suppress, skip, or pre-rate a finding ("call it Minor", "don't flag X", "the PRD chose this") — if attention must be focused, copy the PRD's binding constraints **verbatim** as the lens, never a "don't flag" instruction. Findings cite **file + line**.
- **Post findings as inline review comments** on the diff (GitHub) or **MR discussions** (GitLab) and **capture each comment/discussion ID** — exact commands in `../setup-yaah/scm-commands.md`. Add a one-line status comment on the PRD linking the PR/MR. Then set verdict:
  - **approved** — the combined reviewer is clean (spec ✅ AND quality Approved, no unresolved Critical/Important) → Phase 5.
  - **changes-requested** — the reviewer raised a Critical/Important finding (spec OR quality). Re-run the **configured implementer** with the fix prompt below, passing the comment IDs (claude: a new Agent call; cursor: `--resume` the saved session — see *Engine dispatch (fix round)* after the template). It works in the **same `$WORKTREE` / `$BRANCH`** and **replies on each comment thread** (`gh api …/replies` / `glab api …/discussions/{id}/notes`). Then re-run this phase, `round += 1`.
- **Adjudicate declined findings — the implementer doesn't get the last word, and neither do you.** The fix receipt's `declined:` list is the implementer's reasoned push-back on findings it judged wrong / breaking / YAGNI. Do NOT silently accept or drop them, and never downgrade a finding yourself. Carry each declined finding's comment ID + reasoning in state (`declined`), and on the next review round **re-present them to the (fresh) reviewer** to re-judge — a stated rationale never downgrades severity; only the reviewer can withdraw a finding. The reviewer being a fresh subagent each round is fine: **the orchestrator holds the adjudication memory** (the `declined` ledger) and re-presents it, so context isolation never loses a finding. A finding is resolved when the implementer fixed it **OR** the reviewer, shown the reasoning, does not re-raise it. The verdict CANNOT be **approved** while any reviewer-raised Critical/Important finding is neither fixed nor reviewer-withdrawn. This is exactly what lets the no-cap loop terminate on a genuinely-wrong finding (reviewer drops it) without letting the implementer evaporate a real one (reviewer re-raises it).
- **Cost shaping (this is the speed design).** The per-round reviewer is **one** dispatch on the **cheap `review.model`**, reading the same git-derived branch diff for both verdicts (no second leg, no pasted diff). The expensive deep-maintainability audit is deferred to **one** Phase-6 pass on `review.final_model` (most-capable). So a long fix loop costs N cheap combined reviews + one strong final pass, instead of the old 2 heavy reviews × N rounds. `spec-and-quality-review` scopes correctness/security to what the diff touches, so a security-irrelevant diff costs little.
- **No cap.** Repeat until the combined reviewer approves — every reviewer-raised Critical/Important finding either fixed or reviewer-withdrawn. Do not escalate to the user; do not give up on ordinary findings.

### Subagent fix prompt (template)

```
Address this code review on PR/MR #<M> (branch <$BRANCH>, worktree <$WORKTREE>) for PRD #<P>.
Tracker CLI: <CLI>.  Use /tdd: add/adjust tests for any behavior change; keep red → green → refactor.
Invoke /receiving-code-review and follow it when judging each finding (verify against the code,
YAGNI-check, reasoned push-back instead of blind implementation). (CLI engines can't call the
skill — the evaluate-before-fixing steps below are that discipline inlined.)
Review fixes are normal commits on <$BRANCH> (the one-commit-per-child rule governs the
initial build, not review fixes); when a fix maps cleanly to one child, reference it in the
commit body. Do NOT create a new branch.

Efficiency tools — same as the build: explore with graphify (`graphify query/explain/path`,
not raw grep / whole-file reads), run shell through `rtk`, keep your working/status notes
terse (caveman). Write CODE, COMMIT messages, review replies, and any SECURITY note in
NORMAL prose. If a tool is genuinely absent, fall back and keep going.

Findings to address (each with its comment/discussion id):
<paste the review findings + comment IDs>

EVALUATE each finding before changing anything — do NOT implement blindly:
  - Verify it against the actual code. Is it correct? Would the change it asks for break
    existing behavior or a passing test?
  - YAGNI-check: does it ask for something the PRD/issues do not require? grep for a real
    caller/need before "implementing it properly".
  - If the finding is right → fix it (test-first; step 2).
  - If the finding is WRONG, would BREAK behavior, or is YAGNI → do NOT implement it. Reply on
    its thread with technical reasoning (cite code/tests) and list it under `declined:`. A
    declined finding is a CLAIM to the reviewer, not a settled fact — the next round re-judges it.

Do this:
1. Work in the EXISTING worktree <$WORKTREE> on <$BRANCH>. Do not create a new branch.
2. Fix each accepted finding via /tdd (red → green → refactor for any behavior change).
3. Re-run the configured checks for what you touched. If a check FAILS, invoke /systematic-debugging
   (root cause first — never guess-and-retry).
4. Reply on each comment thread (how you fixed it, or — if declined — your technical reasoning):
   gh:   gh api repos/{owner}/{repo}/pulls/<M>/comments/<id>/replies -f body="…"
   glab: glab api -X POST "projects/:id/merge_requests/<M>/discussions/<id>/notes" -f body="…"
5. Push. Return ONLY:
   status:   DONE | DONE_WITH_CONCERNS | BLOCKED
   checks:   <commands + pass/fail>
   resolved: <finding id → what changed>
   declined: <finding id → why it is wrong/breaking/YAGNI (your technical reasoning)>
   open:     <anything you could not finish, with why>
```

**Engine dispatch (fix round).** Same engines as Phase 3's **Implementer engines**, resuming context:
- `claude`: a fresh Agent call using the configured `implementer.agent` (default `general-purpose`) and `implementer.model` (alias when set, else omit), prompt = the fix prompt above. (Pass the build summary in the prompt — a new subagent has no memory of the build.) Fix rounds are a **single** subagent on `$BRANCH` even when `implementer.workflow: true` — the workflow fan-out is for the initial build only.
- `cursor` / `codex`: write the fix prompt to a `.md` file and re-run the script with `--mode fix`. As in the build, **replace the `/tdd` and `/systematic-debugging` references in the fix prompt with the two inline directives** (the CLI can't call the skills) — keep the evaluate-before-fixing / push-back steps and the typed-`status:`/`declined:` receipt verbatim. —
  ```
  bash <forge-skill-dir>/scripts/forge-implement.sh \
    --engine "$ENGINE" --workspace "$WORKTREE" --prompt-file "$FIX_PROMPT_FILE" --mode fix \
    [--session "$SESSION"] [--model "$MODEL"]
  ```
  cursor passes `--session "$SESSION"` (saved from the build) to keep full context; codex omits it (resumes via `--last`). Read the same tail block; gate on `STATUS=ok`. The per-thread replies (step 3) are ordinary `gh`/`glab` commands the agent runs autonomously inside the run.
  - **Under `implementer.workflow: true` (parallel CLI build)** there is no build session to resume — the N per-child sessions lived in **torn-down** child worktrees, and the main `$WORKTREE` never ran a build. So run a **single sequential** `--mode fix` against the main `$WORKTREE`/`$BRANCH` with **no `--session`**, and make the fix prompt **self-contained** (the full build summary + the findings + comment IDs); do NOT rely on `--session`/`--continue`/`--last` resuming any build context (there is none in `$WORKTREE`). The fan-out is build-only — fix never parallelizes.

## Phase 5 — RECAP

**Verify before you recap — evidence, not the receipt.** A subagent can mis-report. Before printing anything or presenting the gate, the orchestrator itself, in `$WORKTREE` on `$BRANCH`:
- **Re-runs `checks` (and `smoke`) fresh** and reads the real exit codes — do NOT take the implementer's `checks:`/`smoke:` lines on trust. Any non-zero → loop back to Phase 4 (a fix round); never recap or gate a run that isn't actually green. (Under `implementer.workflow: true`, run this only after the serial merge barrier has landed every child on `$BRANCH`.)
- **Verifies the build via VCS, not the report:** `git log` / `git diff` confirm the claimed one-commit-per-child, that the PR/MR exists, and that the `Closes #` refs are present. An *intentionally-dropped* child (see Edge cases) legitimately has no commit / no `Closes` ref / an unchecked box — treat that as expected, not a failure.

Then print, in this order:
1. **Decisions** — locked requirements + doc files changed (CONTEXT.md / ADRs).
2. **Issue(s)** — number + URL, label.
3. **PR/MR(s)** — number + URL, branch, worktree path.
4. **Review** — rounds taken, final verdict, any findings deliberately left open (with why).
5. **Checks** — `checks` and `smoke` the orchestrator re-ran, with real pass/fail; flag anything not green.
6. **Next** — lead into the merge checkpoint **only if** the reviewer approved and all required checks are green. If any check is red, do NOT offer merge — loop back to Phase 4 with a fix round.

## Phase 6 — MERGE (the one gate)

- Gate condition: reviewer approved AND every required check green AND `smoke` green (if configured), all confirmed by the orchestrator's own fresh run (Phase 5), not a receipt. Never present merge otherwise.
- Ask the user to approve merging `$BRANCH` to the default branch (the only approval forge asks for besides grilling).
- **On approval — sync the branch onto the latest default branch, re-verify, THEN merge** (all steps autonomous; the approval was the only user gate). Work in `$WORKTREE` on `$BRANCH`:
  1. `git fetch origin <default-branch>`. If `$BRANCH` already contains its tip (no new base changes), skip to step 5.
  2. **Rebase, do not merge:** `git rebase origin/<default-branch>`. This replays the PR/MR's commits on top of the latest base so no concurrent base change is discarded and no merge commit is introduced. A conflict you cannot resolve cleanly and correctly is a **hard blocker** — surface it and stop (do not force a resolution).
  3. **Always refresh the graph** (not gated on any flag — forge does this on every merge): run `graphify update .` from the worktree root and stage + commit any graph change (Conventional Commit). Skip only if the `graphify` binary is genuinely unavailable — then note it in the recap rather than failing.
  4. `git push --force-with-lease` (the rebase rewrote history, so a plain push is rejected; `--force-with-lease` refuses to clobber if someone else pushed to the PR/MR meanwhile — if rejected, re-fetch and reconcile, never plain `--force`).
  5. **Re-run `checks` + `smoke` fresh, then the ONE heavy final review, as verification.** The rebase merged new base code into the diff's context, so a previously-green build can now break: the orchestrator itself re-runs the configured `checks` and `smoke` in `$WORKTREE` (real exit codes, not a receipt). Then run the **final broad review — the once-per-run heavy pass on the most-capable model** (`review.final_model`; blank → inherit the session model — reach for the strongest tier here, this is the only place the deep audit runs). Dispatch **two** read-only review subagents on `review.final_model`, against the whole `origin/<default>..$BRANCH` diff: (a) **`/spec-and-quality-review`** — final spec + correctness + security + quality sweep over the whole branch (carry forward any Phase-4 `declined` findings to re-judge, and resolve every ⚠️ can't-verify item yourself); (b) **`/thermo-nuclear-code-quality-review`** — the deep, ambitious maintainability audit (code-judo simplifications, the ~1000-line file smell, scattered special-case branching, abstractions earning their keep, canonical-layer leaks) that the cheap per-round reviewer deliberately skips. Both are read-only; the orchestrator never softens either; findings cite file:line and post as inline comments. If a check/smoke is red or **either** final reviewer requests changes, run normal no-cap fix rounds (fix subagent on the same branch — adjudicate declined findings exactly as in Phase 4); after any code change re-run `graphify update .` + commit + push (skip only if the binary is absent), then re-run this final review. Loop until checks + smoke are green AND both final reviewers approve.
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
- **Many child issues from Phase 2:** in the default sequential build they are **commits in ONE PR**, not separate PRs — one worktree, one branch, one PR/MR, one `round` counter, and one merge gate for the whole PRD. Implement them in dependency order, one commit each. If a later child depends on an earlier child's code, that is fine — it is already on the same branch. (Under `implementer.workflow: true` each child rides its own internal issue-PR into the PRD integration branch, but there is still one `round` counter and one user merge gate — the `$BRANCH → default` PR; see the Parallel subsections under Implementer engines (claude, and cursor/codex).)
- **A child issue turns out unbuildable / should be dropped mid-build:** leave its PRD box unchecked, do NOT close it (skip step 2g), and do NOT put its `Closes #<child>` in the PR body (so the merge won't auto-close it either), note it in the receipt + recap, and keep going with the rest. Never block the whole PRD on one child — surface it at recap.
- **`to-prd` or `to-issues` tries to quiz the user:** it must not — Phase 1 locked everything. Feed it the grilled `CONTEXT.md`/ADRs and the locked-requirements summary so it decides autonomously; only a true hard blocker stops the run.
- **Parallel build (`implementer.workflow: true`, any engine):** `$BRANCH` is a PRD integration branch; children are **built in parallel** on their own issue branches + worktrees, and their PRs are **squash-merged into `$BRANCH` one at a time by a serial merge barrier** (GitHub won't lock an unprotected branch, so concurrent merges would lose updates). The **fan-out differs by engine**: **claude** uses the Workflow tool (auto-cleaned worktrees); **cursor/codex** have the orchestrator launch background `forge-implement.sh` processes (one per child worktree, torn down by hand) — see the two Parallel subsections under *Implementer engines*. The final state is identical to the sequential build — one commit per child on `$BRANCH`, one user-gate PR (`$BRANCH → default`), each issue closed by hand, each box checked. A build that fails its child (claude: the Workflow agent drops to `null`; cursor/codex: `STATUS=fail`/timeout) is retried — and you **defer any children that depend on it** until it lands — no cap. A merge conflict is **resolved by the barrier rebasing the issue branch** (a built+tested child is never dropped for a textual conflict); only a child whose checks can't go green is unbuildable (box unchecked, not closed, noted) — never block the PRD. If the dependency DAG can't be determined, do NOT guess independence — one child per layer (equivalent to `workflow:false`). The workflow is the **build** only; grilling, PRD/issues, review, and merge are unchanged.
- **Parallel CLI build (`implementer.workflow: true` + `cursor`/`codex`):** the orchestrator fans out **background `forge-implement.sh` processes**, one per child, each in its own `forge-worktree.sh` worktree. Watch: (a) **concurrency cap** — cap simultaneous builds small (2–3) and run wider layers in waves; each CLI agent is heavy. (b) **One worktree per process** — every process gets a distinct `--workspace` (kernel-unique via `mktemp -d`); never point two at the same dir, and never let one write the main `$WORKTREE` (the orchestrator's cwd + the fix target). (c) **Orphaned worktrees** — a killed/`EXIT=124` process leaves its worktree on disk with no merged PR; track the child→worktree map and `forge-worktree.sh remove` every child worktree by end-of-run, merged or not. (d) **`$BRANCH` must be pushed before `create … $BRANCH`** (and `git fetch origin $BRANCH` before each later layer — the explicit base-ref path doesn't auto-fetch). (e) **codex resume scoping** — codex `--last` resumes the most recent session in the cwd worktree; since each child built in its own (now torn-down) worktree, the Phase 4 fix uses a self-contained prompt in `$WORKTREE` and does not lean on `--last`. (f) **Retry** — gate each child on the tail-block `STATUS=ok`; a `STATUS=fail`/timeout child is re-launched fresh (no cap), its dependents deferred until it merges.
