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

## Phase 2 — ISSUE

- Call the Skill tool with `to-issues` on the locked plan.
- It drafts **tracer-bullet vertical slices** (each cuts through all layers — data/API/UI/tests — demoable on its own), marks each AFK/HITL, and publishes in dependency order via the tracker CLI (`gh issue create` / `glab issue create`) with the configured `issue_label`.
- **Capture** every created issue's number + URL into state.
- **Multiple slices:** process them through Phases 3–6 **one at a time in dependency order** (blockers first). Each slice gets its own worktree, branch, PR/MR, and merge gate; `round`, `worktree`, `branch`, and `pr` are per slice. Re-print the state block when you switch slices. A dependent slice that needs an earlier slice's unmerged code should base its worktree on the blocker's branch: `forge-worktree.sh create <slug> <blocker-branch>` (the script accepts a base-ref), or merge the blocker first.
- Do not modify or close any parent issue.

## Phase 3 — BUILD (handoff → implementer → tdd)

1. Call the Skill tool with `handoff`, scoped to "prompt a fresh agent to implement issue #N via TDD inside `$WORKTREE`." The doc **references the issue by URL** + the grilled decisions/doc changes — it does not restate the issue body.
2. Deliver the build prompt to the **configured implementer engine** (`implementer.engine`, default `claude`) — exact mechanics in **Implementer engines** below. The prompt = the handoff doc + the build contract below, with `<CHECKS>` and `<CLI>` filled from config (and the `/tdd` line adapted per engine).
3. Read the returned receipt; write `pr` (and, for cursor, the session id) into state. A **missing PR/MR after a retry** is a hard blocker. A **failing check is NOT** a blocker — re-run the implementer with tightened guidance (the loop has no cap); only a genuinely unrecoverable failure stops the run.

### Subagent build prompt (template)

```
You are implementing ONE issue end-to-end with TDD, inside an existing git worktree.
Do NOT ask questions — requirements are locked; decide and proceed.

Worktree (your cwd for everything): <$WORKTREE>
Branch (already created, use it): <$BRANCH>
Issue: #<N> — <url>
Tracker CLI: <CLI>            (gh = GitHub, glab = GitLab)
Checks to run: <CHECKS>       (ordered; each MUST exit non-zero on failure)
Locked decisions / handoff: <paste the handoff doc>

Do this:
1. cd into the worktree and confirm you are on <$BRANCH> (git rev-parse --abbrev-ref HEAD).
2. Invoke the /tdd skill and follow it strictly: red → green → refactor, one behavior
   at a time, vertical tracer bullets, behavior tested through public interfaces
   (see tdd/tests.md, tdd/mocking.md). Do NOT create a new branch.
3. Run the configured checks for what you touched (the <CHECKS> list, in order).
   All must pass.
4. Commit (Conventional Commits), push <$BRANCH>, open a PR/MR whose body contains
   "Closes #<N>":
     gh:   gh pr create --base <DEFAULT_BRANCH> --head <$BRANCH> --title T --body "Closes #<N>"
     glab: glab mr create --source-branch <$BRANCH> --target-branch <DEFAULT_BRANCH> --title T --description "Closes #<N>"
   Comment the PR/MR URL on issue #<N> (gh issue comment / glab issue note).
5. Return ONLY this receipt (no prose):
   branch:  <name>
   pr:      #<M> <url>
   checks:  <each command run + pass/fail>
   summary: <2–4 lines: what you built and any caveat>
```

### Implementer engines

The build prompt above and the fix prompt in Phase 4 are **engine-agnostic** — the same text runs under any engine. `implementer.engine` is `claude` (default), `cursor`, or `codex`; `implementer.model` (cursor/codex) optionally overrides the model. A missing block ⇒ `claude`. Receipt format and success contract are identical; only *how* the prompt is delivered and the receipt is read differs. `cursor` and `codex` are **CLI engines** — both run an autonomous coding-agent binary headlessly inside `$WORKTREE`, share the prompt-adaptation + timeout + preflight rules, and differ only in flag syntax and how the receipt is read.

#### `claude` (default) — a Claude Code subagent

Spawn exactly **one** subagent via the Agent tool, `subagent_type: general-purpose` (it needs Bash + the tracker CLI + edit tools), cwd `$WORKTREE`, prompt = the build prompt (Phase 3) or the fix prompt (Phase 4). The subagent's final message **is** the receipt. Fix rounds are a fresh Agent call with the fix prompt.

#### `cursor` — the Cursor Agent CLI

Run the `cursor-agent` CLI (Cursor's coding agent) headlessly against the worktree. Under `-p --force` it edits files and runs shell commands — git, `gh`/`glab`, the configured checks — with no approval prompt, which is exactly what an autonomous builder needs. The binary is `cursor-agent` (an `agent` alias also exists; prefer `cursor-agent` to avoid PATH collisions).

*Preflight* (Phase 0, once per run — each is a hard blocker on failure):
```
cursor-agent --version            # present? else install:  curl https://cursor.com/install -fsS | bash
[ -n "$CURSOR_API_KEY" ] || cursor-agent status   # authed? else  export CURSOR_API_KEY=…  or  cursor-agent login
```

*Build invocation* (pointed at `$WORKTREE`; add `--model "$MODEL"` only when `implementer.model` is set):
```
cursor-agent -p --force --trust \
  --workspace "$WORKTREE" \
  --output-format json \
  "$BUILD_PROMPT"
```
- `-p` = non-interactive/print mode (grants tool access); `--force` = auto-approve edits + shell (alias `--yolo`); `--trust` = skip the workspace-trust prompt (a fresh forge worktree is an "untrusted" dir and would otherwise hang). Both `-p` **and** `--force` are required — `-p` alone only *proposes* changes, never applies them.
- `--output-format json` emits ONE object on success: `{"result":"<final text = the receipt>","session_id":"<uuid>","is_error":false,…}`. Read `.result` for the receipt and **save `.session_id` into state** for fix rounds. (On failure no well-formed JSON is emitted — guard the parse.)
- **Run it under a timeout** — the CLI has known hangs. Invoke via the Bash tool with its `timeout` raised toward the 600000 ms max, and/or prefix `timeout 600` / `gtimeout 600` where that binary exists. A timeout counts as a failed round → re-run with tightened guidance.
- **Success gate: exit code 0 AND `.is_error == false`.** Never infer success from stdout text alone.

*Prompt adaptation (CLI engines — cursor & codex).* Neither CLI has Claude Code skills, so replace the build contract's step 2 — "Invoke the /tdd skill…" — with this inline directive:
> Work strictly test-first in **red → green → refactor** cycles, one behavior at a time. Build **vertical tracer bullets** (a thin slice through every layer), not horizontal layers. Test behavior through **public interfaces**, never implementation details; mock only true external boundaries (network, clock, filesystem), never internal collaborators. Refactor only on green. Do NOT create a new branch.

(Optional alternative: write those standing rules to `$WORKTREE/AGENTS.md` before the run — both `cursor-agent` and `codex` auto-read `AGENTS.md` at the workspace root — and keep the prompt to the actionable task. Inlining is the simpler, self-contained default.)

#### `codex` — the OpenAI Codex CLI

Run the `codex` CLI's non-interactive `exec` subcommand against the worktree. Under `--dangerously-bypass-approvals-and-sandbox` it edits files and runs shell commands (git, `gh`/`glab`, the checks) with no approval prompt and no sandbox — the network access a push/PR needs. (Don't rely on a shell alias for that flag; pass it explicitly.)

*Preflight* (Phase 0, once per run — each a hard blocker on failure):
```
codex --version          # present? else install:  npm i -g @openai/codex   (or brew install codex)
codex login status       # authed? else  codex login   (or set OPENAI_API_KEY / codex login --with-api-key)
```

*Build invocation* (`RECEIPT` is a temp file OUTSIDE the worktree so the agent can't commit it; add `--model "$MODEL"` only when `implementer.model` is set):
```
RECEIPT="$(mktemp)"
codex exec --dangerously-bypass-approvals-and-sandbox \
  --cd "$WORKTREE" \
  --output-last-message "$RECEIPT" \
  "$BUILD_PROMPT"
```
- `exec` = non-interactive (no approval prompts by design); `--dangerously-bypass-approvals-and-sandbox` additionally drops the sandbox so writes + network work. `--cd "$WORKTREE"` sets the working root. `-m/--model` optional (blank ⇒ the model from `~/.codex/config.toml`).
- `--output-last-message "$RECEIPT"` writes the agent's final message to that file — **that file is the receipt.** Read it after the run. (`--json` would stream JSONL events instead; not needed when you only want the receipt.)
- Same **timeout** wrapper as cursor (raise the Bash-tool timeout, optionally prefix `timeout`/`gtimeout`).
- **Success gate: exit code 0** (codex exits non-zero on failure, with the error on stderr; there is no `is_error` field). Read the receipt only on exit 0.

*Fix round (codex).* Resume the build session so context carries over. `codex exec resume` remembers the session's cwd, so it takes **no `--cd`** — run it from inside `$WORKTREE`:
```
codex exec resume --last --dangerously-bypass-approvals-and-sandbox \
  --output-last-message "$RECEIPT" \
  "$FIX_PROMPT"
```
`--last` resumes the most recent session for the current cwd (worktree) — robust across parallel runs since each worktree has its own cwd. For an explicit handle instead, capture the `session_id` from a build run with `--json` and resume by id: `codex exec resume <session_id> …`.

## Phase 4 — REVIEW (loop, no cap)

- **Invoke `/thermo-nuclear-code-quality-review`** (Skill tool) against the PR/MR branch diff. You orchestrate; it runs its full rubric.
- Apply its bar: code-judo simplifications, the ~1000-line file smell, no scattered special-case branching, abstractions earning their keep, logic in the canonical layer. Prefer few high-conviction findings over many cosmetic nits.
- **Post findings as inline review comments** on the diff (GitHub) or **MR discussions** (GitLab) and **capture each comment/discussion ID** — exact commands in `../setup-yaah/scm-commands.md`. Add a one-line status comment on the issue linking the PR/MR. Then set verdict:
  - **approved** — no presumptive blockers remain → Phase 5.
  - **changes-requested** — re-run the **configured implementer** with the fix prompt below, passing the comment IDs (claude: a new Agent call; cursor: `--resume` the saved session — see *Engine dispatch (fix round)* after the template). It works in the **same `$WORKTREE` / `$BRANCH`** and **replies on each comment thread** (`gh api …/replies` / `glab api …/discussions/{id}/notes`). Then re-run this phase, `round += 1`.
- **No cap.** Repeat until approved. Do not escalate to the user; do not give up on ordinary findings.

### Subagent fix prompt (template)

```
Address this code review on PR/MR #<M> (branch <$BRANCH>, worktree <$WORKTREE>) for issue #<N>.
Tracker CLI: <CLI>.  Use /tdd: add/adjust tests for any behavior change; keep red → green → refactor.

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

**Engine dispatch (fix round).** Same engines as Phase 3's **Implementer engines**, but resuming context:
- `claude`: a fresh Agent call (`general-purpose`), prompt = the fix prompt above. (Pass the build summary in the prompt — a new subagent has no memory of the build.)
- `cursor`: re-invoke the saved session so it keeps full build context —
  ```
  cursor-agent -p --force --trust --workspace "$WORKTREE" --resume "$SID" \
    --output-format json "$FIX_PROMPT"
  ```
  `--resume "$SID"` continues the build session captured in state (`--continue` resumes the most recent if the id is lost); add `--model "$MODEL"` if set. Same success gate (exit 0 + `.is_error == false`) and timeout wrapper as the build invocation. For cursor, the per-thread replies (step 3) are ordinary `gh`/`glab` shell commands it runs under `--force`.
- `codex`: resume the build session (run from inside `$WORKTREE`; `resume` takes no `--cd`) —
  ```
  codex exec resume --last --dangerously-bypass-approvals-and-sandbox \
    --output-last-message "$RECEIPT" "$FIX_PROMPT"
  ```
  `--last` continues the most recent session for that worktree's cwd (or pass an explicit `<session_id>`); add `--model "$MODEL"` if set. Receipt = the `$RECEIPT` file; success gate = exit 0. Replies (step 3) are ordinary `gh`/`glab` commands codex runs under bypass.

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
  6. Merge the PR/MR via the tracker CLI (`gh pr merge` / `glab mr merge`, per repo convention).
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
- **Multiple issues from Phase 2:** worktree, branch, PR/MR, and `round` are **per issue**; reset `round` to 0 and create a fresh worktree when you start a new slice.
