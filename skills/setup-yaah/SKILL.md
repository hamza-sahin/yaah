---
name: setup-yaah
description: One-time interactive setup for the yaah harness / forge pipeline. Detects the repo's stack, default branch, and issue tracker, offers to install the token-efficiency tools (graphify, rtk, caveman), asks the user to confirm or adjust, then writes .yaah/config.yml that forge reads. Use when the user first installs yaah, runs /setup-yaah, or when forge reports a missing config.
disable-model-invocation: true
argument-hint: "(no args — interactive)"
---

# setup-yaah

Configure the yaah harness for **this** repository so `/forge` works on any stack and
either GitHub or GitLab. Output is a single file, `.yaah/config.yml`, at the repo root.
forge reads it at Phase 0; everything stack- or tracker-specific lives here, not in the
skill bodies.

Run once per repo. Re-run any time to change choices.

## What it does

1. **Detect**, then **confirm with the user**, then **write `.yaah/config.yml`.** Detect
   sensible defaults from the repo; ask the user one question per setting (offer the
   detected value as the default); never write a value the user did not confirm.
2. **Offer the token-efficiency tools** (graphify, rtk, caveman). For each: detect whether
   it is already installed; if not, show the exact install command and ask before running
   anything (these touch global/machine state or need a Claude Code restart — never install
   silently). Record what is enabled under `tools:` in the config. Recipes live in
   [efficiency-tools.md](efficiency-tools.md).

## Detection heuristics (propose, don't assume)

- **Issue tracker / SCM** — inspect `git remote -v`:
  - host contains `github` → **github** (CLI `gh`)
  - host contains `gitlab` (or a self-hosted GitLab) → **gitlab** (CLI `glab`)
  - otherwise → ask. Confirm the chosen CLI is installed (`gh --version` / `glab --version`) and authenticated (`gh auth status` / `glab auth status`); if not, tell the user how to fix and stop.
- **Default branch** — `git symbolic-ref --short refs/remotes/origin/HEAD` (strip `origin/`), else `git remote show origin | sed -n 's/.*HEAD branch: //p'`, else local `main`/`master`. Blank in the config means "let forge auto-detect at run time" (recommended).
- **Stack & checks** — look for, in priority order, and propose the matching commands:
  - `package.json` → read its `scripts`; propose `npm test` / `npm run lint` / `npm run typecheck` / `npm run build` for those that exist (use the repo's package manager if a lockfile says `pnpm`/`yarn`/`bun`).
  - `pubspec.yaml` → `flutter analyze` + `flutter test` (and golden tests if present).
  - `Cargo.toml` → `cargo test` + `cargo clippy -- -D warnings` + `cargo fmt --check`.
  - `go.mod` → `go test ./...` + `go vet ./...`.
  - `pyproject.toml` / `setup.py` → `pytest` + `ruff check` / `mypy` if configured.
  - `Makefile` with a `test` target → `make test` (and `make lint` if present).
  - `*.gradle*` → `./gradlew test`; `pom.xml` → `mvn test`.
  - none found → ask the user for the test and lint commands.
- **Smoke (does it run?)** — optional; propose a command that proves the built artifact RUNS, distinct from "tests pass": a server → `<build>` then boot + curl a health endpoint; a CLI → run it with `--help` (or a no-op subcommand); an app/lib that compiles → the build/compile command (`npm run build`, `flutter build <target>`, `cargo build`, `go build ./...`, `mvn -q -DskipTests package`). Propose blank for a pure library with nothing to run. The user confirms or clears it.
- **Issue label** — list the tracker's labels (`gh label list` / `glab label list`) and ask which to apply to forge-created issues (e.g. `ready-for-agent`). Blank = none.
- **Implementer engine** — which agent runs forge's Phase 3 build + Phase 4 fix loop. Default **claude** (a Claude Code subagent — no extra setup). Two CLI engines may be offered, each only when its binary is present and authed (warn and keep `claude` otherwise):
  - **cursor** — available when `cursor-agent --version` succeeds. Needs auth ahead of time (non-interactive): `CURSOR_API_KEY`, or a prior `cursor-agent login` (`cursor-agent status` confirms). Model names: `cursor-agent --list-models`.
  - **codex** — available when `codex --version` succeeds. Needs auth: `codex login status` shows logged in, else `codex login` or `OPENAI_API_KEY`. Model = the value in `~/.codex/config.toml` unless overridden.
  `implementer.model` is optional. For **cursor/codex** it is **engine-specific** (a cursor model id is not a valid codex one) — blank uses that engine's default. For **claude** it is an **Agent-tool alias** (`sonnet`/`opus`/`haiku`) — blank inherits the session model.
- **Implementer parallelism + claude-only option:**
  - `implementer.agent` — **claude only** (cursor/codex ignore it): the subagent type forge invokes via the Agent tool (default `general-purpose`). Any built-in or custom type works, but it MUST have Bash + the tracker CLI + edit tools, or the commit/PR/issue-close steps fail. Read-only types (e.g. `Explore`) are invalid here.
  - `implementer.workflow` — **applies to all engines.** `false` (default) runs one implementer that builds the child issues sequentially on the single branch. `true` opts into a **true parallel build**: `$BRANCH` becomes a **PRD integration branch**, and each dependency-independent child is built **in parallel** on its own issue branch in its own worktree, then squash-merged into the PRD branch via its own PR (merges are serialized to avoid lost updates; forge closes each child by hand since those internal PRs don't target the default branch). The fan-out engine differs: **claude** uses the **Workflow tool**; **cursor/codex** have the orchestrator launch one background `forge-implement.sh` per child (each with its own per-child handoff) — heavier, since it runs several concurrent CLI coding agents (forge caps the concurrency). The single user gate is still the one PRD-branch → default merge. Setting it `true` is the user's opt-in for forge to run a parallel build. Review fixes (Phase 4) stay sequential.
- **Token-efficiency tools** — detect each, propose `true` only if already present, and offer to install the rest (full recipes in [efficiency-tools.md](efficiency-tools.md)):
  - **graphify** — `graphify --version` ok or `graphify-out/graph.json` exists → installed. Install: `pip install graphifyy`. Wire per-repo: `graphify .` (first build) + `graphify claude install` (CLAUDE.md section + Glob/Grep hook). forge refreshes it in Phase 6.
  - **rtk** — `rtk --version` ok → installed. Install: `brew install rtk` (or the curl/cargo forms). Wire global hook: `rtk init -g`, then restart Claude Code.
  - **caveman** — `~/.claude/settings.json` has `enabledPlugins."caveman@caveman": true` → installed (the plugin ships no reliable CLI; an unrelated npm `caveman` binary can shadow `caveman --version`, so don't detect by version). Install: `curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash` (Node ≥18), then restart Claude Code.

## Questions to ask (max one decision each, detected value pre-filled)

1. **Issue tracker** — GitHub (`gh`) or GitLab (`glab`)?
2. **Default branch** — `<detected>` or blank for run-time auto-detect?
3. **Checks** — confirm/edit the ordered list of commands the TDD subagent runs and forge re-checks before merge. Each must exit non-zero on failure.
3b. **Smoke** — confirm/edit the optional list of commands that prove the artifact actually runs (or clear it for a library-only repo). Each must exit non-zero on failure.
4. **Issue label** — which label (if any) to tag forge-created issues with?
5. **Implementer engine** — `claude` (default, no setup), `cursor`, or `codex`? Offer a CLI engine only if its binary is installed; if chosen, confirm that engine's auth is set up and optionally ask for a model (blank = that engine's default). For **claude**, optionally ask: which model alias (`sonnet`/`opus`/`haiku`, blank = inherit) and which subagent type (`implementer.agent`, default `general-purpose`). For **any engine**, optionally ask whether to build dependency-independent children **in parallel** (`implementer.workflow`, default `false`) — claude fans out via the Workflow tool, cursor/codex via several concurrent background `forge-implement.sh` processes, so for the CLI engines confirm the machine can take it.
5b. **Review models** (optional — default both blank = inherit the session model) — forge dispatches its reviewers as subagents. Optionally set `review.model` (the per-round combined reviewer — reach for a cheaper alias like `haiku`/`sonnet` to keep the loop cheap) and `review.final_model` (the once-per-run heavy Phase-6 review — reach for the most-capable alias like `opus`). Both accept `sonnet`/`opus`/`haiku`; blank inherits. Most users leave these blank.
6. **graphify** — codebase knowledge graph? If absent, offer to `pip install graphifyy` + build + wire the hook. forge refreshes it in Phase 6. (`true`/`false`)
7. **rtk** — global token-saving Bash proxy? If absent, offer to install + `rtk init -g`. (`true`/`false`)
8. **caveman** — global terse-output mode? If absent, offer to install. (`true`/`false`)

For each of 6–8, if the tool is missing run the install only after the user agrees, then continue regardless of their choice (these are optional — a "no" just records `false`).

## Output — `.yaah/config.yml`

Write exactly this shape (fill from the confirmed answers). Keep the comments.

```yaml
# .yaah/config.yml — generated by /setup-yaah. forge reads this at Phase 0.
# Re-run /setup-yaah to change any value.

scm: github            # github | gitlab
cli: gh                # gh | glab   (must match scm)
default_branch: ""     # branch name, or "" to auto-detect origin's default at run time
issue_label: ""        # label applied to forge-created issues, or "" for none

# Commands the TDD subagent runs after touching code, and that forge re-checks
# before merge. Run in order; each MUST exit non-zero on failure.
checks:
  - "npm test"

# Optional: commands that prove the built artifact actually RUNS, not just that
# tests/lint pass (boot the server + curl a health endpoint, run the CLI --help,
# `<build>` then start). Run after checks in the build and re-run in Phase 6.
# Leave empty for a library-only repo. Each MUST exit non-zero on failure.
smoke: []

# Engine that runs forge's Phase 3 build and every Phase 4 fix round.
#   claude = a Claude Code subagent (Agent tool) — no extra setup.
#   cursor = the `cursor-agent` CLI headless in the worktree
#            (needs cursor-agent installed + CURSOR_API_KEY or `cursor-agent login`).
#   codex  = the OpenAI `codex exec` CLI headless in the worktree
#            (needs codex installed + `codex login` or OPENAI_API_KEY).
implementer:
  engine: claude          # claude | cursor | codex
  model: ""               # claude: sonnet|opus|haiku (an Agent-tool alias); cursor/codex: engine-specific id; "" = inherit/default
  agent: general-purpose  # claude only: which subagent type to invoke (must have Bash + tracker CLI + edit tools)
  workflow: false         # all engines: true = build child issues in PARALLEL — claude via the Workflow tool, cursor/codex via one background forge-implement.sh per child. $BRANCH becomes a PRD integration branch, each child built on its own issue branch + worktree and merged in via its own PR (one user gate stays: PRD branch -> default). false = one sequential implementer on one branch.

# Models for forge's reviewers (both optional; "" = inherit the session model).
# Reviews are dispatched subagents — naming a model keeps each round cheap and
# stops it silently inheriting the session's most-expensive tier.
#   model       = the per-round combined reviewer (spec + correctness + security +
#                 focused quality, one pass). Runs every Phase 4 round — reach for a
#                 cheaper tier here.
#   final_model = the once-per-run heavy review at the Phase 6 gate (deep maintainability
#                 audit + final spec/quality sweep). Reach for the most-capable tier.
# Values are Agent-tool aliases: sonnet | opus | haiku.  "" = inherit session model.
review:
  model: ""               # per-round combined reviewer (cheap/scaled); "" = inherit
  final_model: ""         # Phase 6 heavy final review (most-capable); "" = inherit

# Token-efficiency tools (all optional, independent). graphify is per-repo and
# consumed by forge; rtk and caveman are global/machine-level and work via their
# own hooks — the booleans record the recommended stack. See efficiency-tools.md.
tools:
  graphify: false      # codebase knowledge graph; forge runs `graphify update .` in Phase 6
  rtk: false           # token-saving Bash proxy (global PreToolUse hook)
  caveman: false       # terse-output agent mode (global Claude Code plugin)
```

After writing it:
- Print the final config back to the user.
- Add `.yaah/config.yml` to the repo (commit it so the whole team + every agent share one setup), unless the user prefers to gitignore it.
- For **GitLab**, remind the user that forge maps PR→MR and uses `glab`; the exact command recipes for both trackers live in [scm-commands.md](scm-commands.md).

## Notes

- This skill only writes config and (with consent) runs installers; it does not change skill bodies. forge stays stack-agnostic and reads `cli`, `checks`, `smoke`, `default_branch`, `issue_label`, `implementer.*`, `review.*`, and `tools.*` from the file.
- **Implementer engine is `claude` unless the user opts into a CLI engine (`cursor` or `codex`).** Never write a CLI engine without confirming its binary is installed AND its auth is set up — an unauthed CLI engine hard-blocks forge at Phase 0. When switching engines, reset `model` (ids don't transfer between engines — and the claude vocabulary is the `sonnet`/`opus`/`haiku` aliases, not a cursor/codex id). `agent` is claude-only and ignored by the CLI engines; `workflow` is honored by all engines (cursor/codex fan out via background `forge-implement.sh` instead of the Workflow tool). A missing `implementer` block (or missing `agent`/`workflow`) is read by forge as `claude` / `general-purpose` / `workflow:false` (backward-compatible).
- **Never install a global tool (rtk, caveman) or pip package without the user's explicit OK.** Show the command, confirm, then run it. rtk and caveman need a Claude Code restart to take effect — tell the user.
- The `tools:` block is optional in older configs; forge also honors a legacy top-level `graphify:` key. New configs should use the block.
- If `.yaah/config.yml` already exists, show it and ask which fields to change rather than starting over.
