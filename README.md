<p align="center">
  <img src="docs/assets/yaah-banner.gif" alt="yaah — one prompt → GRILL → ISSUE → BUILD (TDD) → PR/MR → strict REVIEW LOOP → REBASE → MERGE, in isolated worktrees" width="100%">
</p>

<p align="center">
  <em><code>/forge</code> in ten seconds</em>
</p>

# yaah — Yet Another Agent Harness

A lightweight, opinionated harness for **Claude Code** that turns a one-line prompt into a
reviewed, merge-ready pull/merge request — with almost no babysitting.

Its centerpiece is **`/forge`**: a single skill that chains five focused skills into
one autonomous pipeline. You answer questions during a requirements grilling, then
approve once before merge. Everything in between — issue creation, implementation,
code review, fix loops, knowledge-graph refresh, rebasing onto the latest default
branch — runs hands-off, each step inside an isolated git worktree so you can run many
forges in parallel without them colliding.

**This is built for real software engineers who want to ship — and align properly while
they do it.** Not a demo, not a vibe-coding toy that hands you a pile of unreviewed
diffs. `/forge` is opinionated about what "done" means, and a few principles run through
the whole thing:

- **Alignment before code.** Nothing gets built until the requirements are pinned down
  with you. The grilling phase is where you and the agent agree on *what* and *why*; the
  rest of the pipeline is just honoring that contract.
- **Ship reviewed work, never raw output.** Every change is test-driven and run through
  a strict review→fix loop until it's clean — no round limit, no "good enough." What
  lands is something you'd be comfortable putting your name on.
- **Stay in the loop where it matters, out of it where it doesn't.** Two human
  touchpoints — the requirements interview and the final merge approval. Between them the
  agent doesn't pester you; it just does the work and fixes its own mistakes.
- **Never merge blindly.** The one approval rebases onto the latest default branch and
  re-runs review against the freshly-merged context before it merges. Your main branch
  stays honest.
- **Reuse the community's best, don't reinvent.** Each phase is a real, standalone skill
  from people who solved that problem well — `/forge` is the glue, not a monolith.

**Stack-agnostic and tracker-agnostic.** forge works on any language/build system and
with either **GitHub (`gh`)** or **GitLab (`glab`)**. It carries no hardcoded stack: a
one-time `/setup-yaah` interview writes a per-repo `.yaah/config.yml` (tracker, default
branch, test/lint commands, issue label, token-efficiency tools) that forge reads at run time.

---

## Why this exists

Good agent skills already exist for the individual steps — interrogating a plan,
slicing it into issues, writing tests first, reviewing for quality. The friction is
**stitching them together**: remembering the order, carrying state between them, not
dropping the ball between "tests pass" and "actually merged". `/forge` encodes that
glue once, as a contract:

- **Two human touchpoints, no more.** You're in the loop for the requirements
  interview and the final merge approval. Between them the pipeline does not stop to
  ask — a failing test just triggers another fix round; only a true hard blocker
  (no repo, no auth, an unresolvable rebase conflict) halts the run.
- **No review-round cap.** The review→fix loop repeats until the reviewer is
  satisfied, not until a counter runs out.
- **Isolated by construction.** Each run gets its own worktree branched off the latest
  default branch. The main checkout is never touched until you approve the merge, so N
  concurrent runs never step on each other.
- **Config-driven, not hardcoded.** No stack or tracker assumptions live in the skills;
  they all come from `.yaah/config.yml`, so the same harness fits a Flutter app, a Rust
  crate, a Go service, or a Node monorepo on GitHub or GitLab.
- **Reuse, don't reinvent.** Every phase invokes a real, independently-useful skill.
  `/forge` is orchestration, not a monolith — you can still use each sub-skill alone.

---

## Quick start

```bash
git clone https://github.com/hamza-sahin/yaah.git
cd yaah
./install.sh                         # global: ~/.claude/skills
# or: ./install.sh --project /path/to/repo
```

Then, inside Claude Code in your project:

```
/setup-yaah        # once per repo — interviews you, writes .yaah/config.yml
/forge add a dark-mode toggle to settings
```

`/setup-yaah` detects your stack and tracker, confirms each choice with you, and writes
the config. `/forge` then runs the full pipeline.

---

## The flow

```
/forge <what to build or fix>

Phase 0  CONFIG+WT read .yaah/config.yml, create an isolated worktree off the
                   latest default branch, cd in   (runs /setup-yaah if no config)
Phase 1  GRILL     /grill-with-docs        interactive — lock requirements + docs
Phase 2  ISSUE     /to-issues              create issue(s) on GitHub or GitLab
Phase 3  BUILD     /handoff → subagent → /tdd
                                           implement test-first, open a PR/MR, link the issue
Phase 4  REVIEW    /thermo-nuclear-code-quality-review
                                           review → fix loop until clean (no cap)
Phase 5  RECAP     summarize the run
Phase 6  MERGE     ── the one approval ──
                   on approval: rebase onto latest default branch → graphify (if on) →
                   force-push → re-run the review loop once to verify → merge →
                   tear the worktree down
```

**Phase 6 in detail.** When you approve, `/forge` does not merge blindly. It fetches
the default branch, **rebases** the PR/MR branch onto the latest tip (a rebase, never a
merge commit, so concurrent changes are preserved rather than papered over), refreshes
the knowledge graph if enabled, force-pushes with `--force-with-lease`, and runs the
review loop **one more time** as verification against the freshly-merged context. Only
when that pass is clean does it merge. An unresolvable rebase conflict is surfaced as a
hard blocker instead of being forced.

---

## What's in the box

| Skill | Role | Standalone | Source |
|-------|------|------------|--------|
| **setup-yaah** | One-time interactive setup. Detects stack + tracker + default branch, confirms with you, offers to install the token-efficiency tools, writes `.yaah/config.yml`. Bundles `scm-commands.md` (the GitHub-vs-GitLab command recipes) and `efficiency-tools.md` (graphify/rtk/caveman install + wiring). | run once | yaah |
| **forge** | The orchestrator. `SKILL.md` is the spine; `PLAYBOOK.md` holds per-phase mechanics + subagent prompt templates; `scripts/forge-worktree.sh` creates/removes isolated worktrees and auto-detects the default branch. | — | yaah |
| **grill-with-docs** | Phase 1 — interrogates the plan against your domain model, sharpens terminology, updates `CONTEXT.md` / ADRs inline. | ✅ | [mattpocock](#credits) |
| **to-issues** | Phase 2 — breaks the locked plan into tracer-bullet vertical slices and files them in dependency order. | ✅ | [mattpocock](#credits) |
| **handoff** | Phase 3 — compacts context into a tight brief for the implementing subagent. | ✅ | [mattpocock](#credits) |
| **tdd** | Phase 3 — red→green→refactor, behavior tested through public interfaces. Bundles `tests.md`, `mocking.md`, `deep-modules.md`, `interface-design.md`, `refactoring.md`. | ✅ | [mattpocock](#credits) |
| **thermo-nuclear-code-quality-review** | Phase 4 — an unusually strict maintainability review hunting "code-judo" simplifications, giant files, spaghetti growth. | ✅ | [cursor](#credits) |

Only **forge** and **setup-yaah** are original to yaah. The five sub-skills are
third-party work — see [Credits](#credits).

---

## Token-efficiency tools

`/setup-yaah` also offers to install three optional, independent tools that cut token
use while an agent works your repo. It detects each, shows the exact install command,
and asks before running anything (these touch global state or need a Claude Code
restart). Full recipes live in `setup-yaah/efficiency-tools.md`; choices are recorded
under `tools:` in `.yaah/config.yml`.

| Tool | Saves | Scope | forge integration |
|------|-------|-------|-------------------|
| **[graphify](https://github.com/safishamsi/graphify)** | input — query a codebase graph instead of grepping/reading raw files | binary global; graph + hook **per-repo** | refreshes the graph in Phase 6 (`graphify update .`) |
| **[rtk](https://github.com/rtk-ai/rtk)** | input — rewrites shell commands to token-lean equivalents | **global** (machine-level) | transparent — works via its own hook |
| **[caveman](https://github.com/JuliusBrussee/caveman)** | output — answers the agent gives are made terse | **global** (machine-level) | transparent — works via its own hook |

Only **graphify** changes forge's behavior; **rtk** and **caveman** operate entirely
through their global Claude Code hooks, so the agent (and forge's subagents) benefit
without forge doing anything. Enable any subset — they're orthogonal.

---

## `.yaah/config.yml`

Written by `/setup-yaah`, read by `/forge`. Example:

```yaml
scm: github            # github | gitlab
cli: gh                # gh | glab   (must match scm)
default_branch: ""     # branch name, or "" to auto-detect origin's default
issue_label: ""        # label applied to forge-created issues, or "" for none
checks:                # run in order; each MUST exit non-zero on failure
  - "npm test"
  - "npm run lint"

tools:                 # token-efficiency tools (all optional, independent)
  graphify: false      # codebase knowledge graph; forge runs `graphify update .` in Phase 6
  rtk: false           # token-saving Bash proxy (global PreToolUse hook)
  caveman: false       # terse-output agent mode (global Claude Code plugin)
```

> Older configs may carry a top-level `graphify: true` instead of the `tools:` block;
> forge still honors it. New configs written by `/setup-yaah` use the block.

Commit it so your whole team — and every agent — shares one setup. Re-run `/setup-yaah`
anytime to change a value.

---

## Requirements

- **Claude Code** (skills + the Skill/Agent tools).
- **git ≥ 2.5** — `forge-worktree.sh` uses `git worktree`.
- **A tracker CLI, authenticated:**
  - GitHub → [`gh`](https://cli.github.com/) (`gh auth login`)
  - GitLab → [`glab`](https://gitlab.com/gitlab-org/cli) (`glab auth login`)
- *(optional)* **Token-efficiency tools** — `/setup-yaah` can install them, or do it yourself:
  - **graphify** → `pip install graphifyy` (if `tools.graphify: true`, Phase 6 runs `graphify update .`; if absent, forge notes it and continues).
  - **rtk** → `brew install rtk` then `rtk init -g` (global Bash proxy; restart Claude Code).
  - **caveman** → `curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash` (Node ≥18; restart Claude Code).

No language/runtime is required by yaah itself — your `checks` commands decide what runs.

---

## Credits

yaah only exists because the community shared its work first. 🙏 We wrote the glue —
the orchestration (`forge`) and the setup interview (`setup-yaah`) are ours — but the
five skills it chains together come from people who figured the hard parts out before
us. Huge thanks to them:

- **[mattpocock/skills](https://github.com/mattpocock/skills)** — `grill-with-docs`,
  `to-issues`, `handoff`, and `tdd` are from Matt Pocock's lovely skills collection. Go
  star his repo.
- **[cursor/plugins](https://github.com/cursor/plugins/blob/main/cursor-team-kit/skills/thermo-nuclear-code-quality-review/SKILL.md)**
  — `thermo-nuclear-code-quality-review` comes from the Cursor team kit. Thanks, Cursor
  folks.

We vendor these here so the pipeline works the moment you clone it — but please check
out the upstream repos for the canonical versions, updates, and licenses. And if you're
one of the authors: this is *your* work, so if you'd like the attribution worded
differently, a link changed, or a submodule reference instead of a vendored copy, just
open an issue and we'll happily sort it out.

The optional token-efficiency tools are separate projects we don't vendor — yaah simply
installs and configures them once you say yes. Big thanks to the people behind them too:

- **[graphify](https://github.com/safishamsi/graphify)** by Safi Shamsi — codebase
  knowledge graph (`pip install graphifyy`).
- **[rtk](https://github.com/rtk-ai/rtk)** by rtk-ai — token-saving command proxy.
- **[caveman](https://github.com/JuliusBrussee/caveman)** by Julius Brussee — terse
  agent-output mode.

---

## Nominate a skill

yaah is lightweight on purpose, but it's far from finished — and we'd genuinely love your
help shaping it. Know a skill that would sharpen one of the phases, or replace a manual
step with something repeatable? Bring it to us:

- **Got an idea?** Open an issue titled `nominate: <skill-name>` — even a rough sketch
  is welcome. Tell us which phase it improves (or whether it's a whole new one) and why
  it'd beat what we do today.
- **Ready to ship it?** Open a PR adding it under `.claude/skills/`, with a one-line
  entry in the table above and a note in Credits so its author gets the love.
- **Just here to chat?** Issues and discussions are open. Questions, half-baked
  thoughts, and "wouldn't it be cool if…" are all fair game.

We'll always credit where things came from, and we'll always tell you what we think.
Looking forward to building this with you. 🚀

## License

[MIT](LICENSE) © Hamza Sahin — applies to the original yaah work (`forge`,
`setup-yaah`, README, `install.sh`). Vendored sub-skills remain under their upstream
licenses; see [Credits](#credits).
