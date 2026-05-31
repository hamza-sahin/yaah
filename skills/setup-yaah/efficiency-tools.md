# Token-efficiency tools — install & wiring recipes

Three optional, independent tools that cut token use while an agent works this repo.
`/setup-yaah` detects each, offers to install + wire it, and records the choice under
`tools:` in `.yaah/config.yml`. They are orthogonal — enable any subset.

| Tool | Saves | Scope | forge uses it? |
|---|---|---|---|
| **graphify** | input — query a codebase graph instead of grepping/reading raw files | binary global; graph + hook **per-repo** | yes — refreshes the graph in Phase 6 |
| **rtk** | input — rewrites shell commands to token-lean equivalents | **global** (machine-level) | transparent — no forge action |
| **caveman** | output — makes the agent answer tersely | **global** (machine-level) | transparent — no forge action |

"Global" tools affect every project and session on the machine, so install them once.
graphify's binary is global too, but its graph, hook, and `graphify-out/` are per-repo.

---

## graphify — codebase knowledge graph

Maps the repo into a queryable graph so the agent asks `graphify query "…"` (a small
scoped subgraph) instead of grepping or reading whole files.

```bash
pip install graphifyy            # installs the `graphify` binary (global)
graphify .                       # first full build at the repo root → graphify-out/
graphify claude install          # writes a CLAUDE.md section + a per-repo .claude/settings.json
                                 #   PreToolUse hook that nudges Glob/Grep toward the graph
```

- **Incremental refresh:** `graphify update .` — re-extracts only changed files and merges
  them in (AST-only, no API cost). This is what forge runs in Phase 6.
- **Query:** `graphify query "<question>"` · `graphify path "<A>" "<B>"` · `graphify explain "<concept>"`.
- **`graphify-out/`** holds `graph.json` (persistent graph), `GRAPH_REPORT.md` (god nodes +
  suggested questions), `graph.html` (interactive), and `cache/` (SHA256 — only changed
  files re-process). Commit `graphify-out/` to share the graph with the team, or gitignore it.
- **Verify:** `graphify --version`; confirm `graphify-out/graph.json` exists.

forge consumes this via `tools.graphify: true`. If the binary is missing at run time,
forge notes it and continues — it never hard-fails on graphify.

---

## rtk — token-saving Bash proxy

A `PreToolUse` hook transparently rewrites supported shell commands (`git status`,
`ls`, `wc`, `grep`, …) into token-lean `rtk` equivalents before the shell runs them.

```bash
brew install rtk                                                              # recommended
# or: curl -fsSL https://raw.githubusercontent.com/rtk-ai/rtk/refs/heads/master/install.sh | sh
# or: cargo install --git https://github.com/rtk-ai/rtk
rtk init -g                                                                   # register the global hook
```

`rtk init -g` adds a global `PreToolUse` hook on the `Bash` matcher that runs
`rtk hook claude`. **Restart Claude Code** for it to take effect.

- **Verify:** `rtk --version` · `rtk gain` (token-savings stats; `rtk gain --history` for usage).
- **Scope:** only Bash tool calls are rewritten — built-in `Read`/`Grep`/`Glob` bypass the
  hook, so call `rtk` directly (or use the dedicated tools) for those.
- **Permissions:** to auto-allow specific subcommands, add e.g. `Bash(rtk wc *)`,
  `Bash(rtk ls *)`, `Bash(rtk grep *)` to `~/.claude/settings.json` → `permissions.allow`.

---

## caveman — terse agent output

Rewrites the agent's own replies in a compressed "caveman" register (drops articles,
filler, pleasantries) to cut **output** tokens. Installed as a Claude Code plugin whose
hooks auto-activate each session.

```bash
curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash
# Windows (PowerShell 5.1+): irm https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.ps1 | iex
```

Requires Node ≥18. The installer enables the `caveman@caveman` plugin and registers a
`SessionStart` hook (`caveman-activate.js`) plus a `UserPromptSubmit` hook
(`caveman-mode-tracker.js`); **restart Claude Code** so the session picks them up.

- **Levels:** `/caveman lite|full|ultra|wenyan` (filler-drop → telegraphic → classical
  Chinese); the level persists until session end. `/caveman-stats` shows savings.
- **Off:** say `normal mode` (or `/caveman` to toggle). Code, commits, and security text
  stay in normal prose regardless of level.
- **Verify:** confirm `~/.claude/settings.json` → `enabledPlugins."caveman@caveman": true`
  (the plugin has no reliable version CLI — an unrelated npm `caveman` package can shadow
  `caveman --version`, so don't rely on it).

---

## What setup-yaah records

```yaml
tools:
  graphify: true     # per-repo graph; forge refreshes it in Phase 6
  rtk: true          # global Bash proxy
  caveman: true      # global terse-output plugin
```

The booleans capture the efficiency stack this repo recommends and what setup wired up.
Only `graphify` changes forge's behavior; `rtk` and `caveman` operate entirely through
their global hooks, so the agent benefits without forge doing anything.
