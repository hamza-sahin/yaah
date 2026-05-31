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
- **Issue label** — list the tracker's labels (`gh label list` / `glab label list`) and ask which to apply to forge-created issues (e.g. `ready-for-agent`). Blank = none.
- **Implementer engine** — which agent runs forge's Phase 3 build + Phase 4 fix loop. Default **claude** (a Claude Code subagent — no extra setup). Detect **cursor** as available when `cursor-agent --version` succeeds; offer it only then. The cursor engine is non-interactive, so it needs auth ahead of time: `CURSOR_API_KEY` in the environment, or a prior `cursor-agent login` (`cursor-agent status` confirms). Warn (don't write `cursor`) if neither is present. `implementer.model` is optional — blank uses the CLI's default; `cursor-agent --list-models` lists valid names.
- **Token-efficiency tools** — detect each, propose `true` only if already present, and offer to install the rest (full recipes in [efficiency-tools.md](efficiency-tools.md)):
  - **graphify** — `graphify --version` ok or `graphify-out/graph.json` exists → installed. Install: `pip install graphifyy`. Wire per-repo: `graphify .` (first build) + `graphify claude install` (CLAUDE.md section + Glob/Grep hook). forge refreshes it in Phase 6.
  - **rtk** — `rtk --version` ok → installed. Install: `brew install rtk` (or the curl/cargo forms). Wire global hook: `rtk init -g`, then restart Claude Code.
  - **caveman** — `~/.claude/settings.json` has `enabledPlugins."caveman@caveman": true` → installed (the plugin ships no reliable CLI; an unrelated npm `caveman` binary can shadow `caveman --version`, so don't detect by version). Install: `curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash` (Node ≥18), then restart Claude Code.

## Questions to ask (max one decision each, detected value pre-filled)

1. **Issue tracker** — GitHub (`gh`) or GitLab (`glab`)?
2. **Default branch** — `<detected>` or blank for run-time auto-detect?
3. **Checks** — confirm/edit the ordered list of commands the TDD subagent runs and forge re-checks before merge. Each must exit non-zero on failure.
4. **Issue label** — which label (if any) to tag forge-created issues with?
5. **Implementer engine** — `claude` (default, no setup) or `cursor`? Offer `cursor` only if `cursor-agent` is installed; if chosen, confirm `CURSOR_API_KEY`/login is set and optionally ask for a model (blank = the CLI's default).
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

# Engine that runs forge's Phase 3 build and every Phase 4 fix round.
#   claude = a Claude Code subagent (Agent tool) — no extra setup.
#   cursor = the `cursor-agent` CLI run headlessly in the worktree
#            (needs cursor-agent installed + CURSOR_API_KEY or `cursor-agent login`).
implementer:
  engine: claude       # claude | cursor
  model: ""            # cursor only: model override; "" = the CLI's default (see `cursor-agent --list-models`)

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

- This skill only writes config and (with consent) runs installers; it does not change skill bodies. forge stays stack-agnostic and reads `cli`, `checks`, `default_branch`, `issue_label`, `implementer.*`, and `tools.*` from the file.
- **Implementer engine is `claude` unless the user opts into `cursor`.** Never write `cursor` without confirming `cursor-agent` is installed AND auth is set up — an unauthed cursor engine hard-blocks forge at Phase 0. A missing `implementer` block is read by forge as `claude` (backward-compatible).
- **Never install a global tool (rtk, caveman) or pip package without the user's explicit OK.** Show the command, confirm, then run it. rtk and caveman need a Claude Code restart to take effect — tell the user.
- The `tools:` block is optional in older configs; forge also honors a legacy top-level `graphify:` key. New configs should use the block.
- If `.yaah/config.yml` already exists, show it and ask which fields to change rather than starting over.
