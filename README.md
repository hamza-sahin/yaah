# yaah — Yet Another Agent Harness

A small, opinionated harness for **Claude Code** that turns a one-line prompt into a
reviewed, merge-ready pull/merge request — with almost no babysitting.

Its centerpiece is **`/forge`**: a single skill that chains five focused skills into
one autonomous pipeline. You answer questions during a requirements grilling, then
approve once before merge. Everything in between — issue creation, implementation,
code review, fix loops, knowledge-graph refresh, rebasing onto the latest default
branch — runs hands-off, each step inside an isolated git worktree so you can run many
forges in parallel without them colliding.

**Stack-agnostic and tracker-agnostic.** forge works on any language/build system and
with either **GitHub (`gh`)** or **GitLab (`glab`)**. It carries no hardcoded stack: a
one-time `/setup-yaah` interview writes a per-repo `.yaah/config.yml` (tracker, default
branch, test/lint commands, issue label, graphify on/off) that forge reads at run time.

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

| Skill | Role | Standalone |
|-------|------|------------|
| **setup-yaah** | One-time interactive setup. Detects stack + tracker + default branch, confirms with you, writes `.yaah/config.yml`. Bundles `scm-commands.md` (the GitHub-vs-GitLab command recipes forge uses). | run once |
| **forge** | The orchestrator. `SKILL.md` is the spine; `PLAYBOOK.md` holds per-phase mechanics + subagent prompt templates; `scripts/forge-worktree.sh` creates/removes isolated worktrees and auto-detects the default branch. | — |
| **grill-with-docs** | Phase 1 — interrogates the plan against your domain model, sharpens terminology, updates `CONTEXT.md` / ADRs inline. | ✅ |
| **to-issues** | Phase 2 — breaks the locked plan into tracer-bullet vertical slices and files them in dependency order. | ✅ |
| **handoff** | Phase 3 — compacts context into a tight brief for the implementing subagent. | ✅ |
| **tdd** | Phase 3 — red→green→refactor, behavior tested through public interfaces. Bundles `tests.md`, `mocking.md`, `deep-modules.md`, `interface-design.md`, `refactoring.md`. | ✅ |
| **thermo-nuclear-code-quality-review** | Phase 4 — an unusually strict maintainability review hunting "code-judo" simplifications, giant files, spaghetti growth. | ✅ |

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
graphify: false        # run `graphify update .` to refresh a knowledge graph in Phase 6
```

Commit it so your whole team — and every agent — shares one setup. Re-run `/setup-yaah`
anytime to change a value.

---

## Requirements

- **Claude Code** (skills + the Skill/Agent tools).
- **git ≥ 2.5** — `forge-worktree.sh` uses `git worktree`.
- **A tracker CLI, authenticated:**
  - GitHub → [`gh`](https://cli.github.com/) (`gh auth login`)
  - GitLab → [`glab`](https://gitlab.com/gitlab-org/cli) (`glab auth login`)
- *(optional)* **graphify** — if `graphify: true`, Phase 6 runs `graphify update .`. If
  it isn't installed, forge notes it and continues.

No language/runtime is required by yaah itself — your `checks` commands decide what runs.

---

## License

[MIT](LICENSE) © Hamza Sahin
