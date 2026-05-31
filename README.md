# yaah — Yet Another Agent Harness

A small, opinionated harness for **Claude Code** that turns a one-line prompt into a
reviewed, merge-ready pull request — with almost no babysitting.

Its centerpiece is **`/forge`**: a single skill that chains five focused skills into
one autonomous pipeline. You answer questions during a requirements grilling, then
approve once before merge. Everything in between — issue creation, implementation,
code review, fix loops, knowledge-graph refresh, rebasing onto latest `master` —
runs hands-off, each step inside an isolated git worktree so you can run many forges
in parallel without them colliding.

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
- **Isolated by construction.** Each run gets its own worktree branched off the
  latest `master`. The main checkout is never touched until you approve the merge,
  so N concurrent runs never step on each other.
- **Reuse, don't reinvent.** Every phase invokes a real, independently-useful skill.
  `/forge` is orchestration, not a monolith — you can still use each sub-skill alone.

---

## The flow

```
/forge <what to build or fix>

Phase 0  WORKTREE  create an isolated worktree off latest master, cd in
Phase 1  GRILL     /grill-with-docs        interactive — lock requirements + docs
Phase 2  ISSUE     /to-issues              create issue(s) on the tracker
Phase 3  BUILD     /handoff → subagent → /tdd
                                           implement test-first, open a PR, link the issue
Phase 4  REVIEW    /thermo-nuclear-code-quality-review
                                           review → fix loop until clean (no cap)
Phase 5  RECAP     summarize the run
Phase 6  MERGE     ── the one approval ──
                   on approval: rebase onto latest master → graphify update →
                   force-push → re-run the review loop once to verify → merge →
                   tear the worktree down
```

**Phase 6 in detail.** When you approve, `/forge` does not merge blindly. It fetches
`origin/master`, **rebases** the PR branch onto the latest tip (a rebase, never a
merge commit, so concurrent changes on `master` are preserved rather than papered
over), refreshes the knowledge graph, force-pushes with `--force-with-lease`, and
runs the review loop **one more time** as verification against the freshly-merged
context. Only when that pass is clean does it merge. An unresolvable rebase conflict
is surfaced as a hard blocker instead of being forced.

---

## What's in the box

| Skill | Role in the pipeline | Usable standalone |
|-------|----------------------|-------------------|
| **forge** | The orchestrator. `SKILL.md` is the spine; `PLAYBOOK.md` holds per-phase mechanics + the subagent prompt templates; `scripts/forge-worktree.sh` creates/removes isolated worktrees. | — |
| **grill-with-docs** | Phase 1 — interrogates the plan against your domain model, sharpens terminology, updates `CONTEXT.md` / ADRs inline. | ✅ |
| **to-issues** | Phase 2 — breaks the locked plan into tracer-bullet vertical slices and publishes them to the issue tracker in dependency order. | ✅ |
| **handoff** | Phase 3 — compacts context into a tight brief for the implementing subagent. | ✅ |
| **tdd** | Phase 3 — red→green→refactor, behavior tested through public interfaces. Bundles `tests.md`, `mocking.md`, `deep-modules.md`, `interface-design.md`, `refactoring.md`. | ✅ |
| **thermo-nuclear-code-quality-review** | Phase 4 — an unusually strict maintainability review hunting for "code-judo" simplifications, giant files, and spaghetti growth. | ✅ |

---

## Install

These are [Claude Code skills](https://docs.claude.com/en/docs/claude-code). Drop them
where Claude Code looks for skills — globally (`~/.claude/skills/`) for every project,
or per-project (`<repo>/.claude/skills/`).

### One-liner

```bash
git clone https://github.com/hamza-sahin/yaah.git
cd yaah
./install.sh            # installs to ~/.claude/skills (global)
./install.sh --project /path/to/repo   # installs to <repo>/.claude/skills instead
```

### Manual

```bash
# global, for all projects
cp -R skills/* ~/.claude/skills/

# or per-project
cp -R skills/* /path/to/your/repo/.claude/skills/
```

Make sure the worktree script stays executable:

```bash
chmod +x ~/.claude/skills/forge/scripts/forge-worktree.sh
```

### Verify

Restart Claude Code (or start a new session) and run:

```
/forge
```

You should see forge kick off Phase 0.

---

## Requirements

- **Claude Code** (skills + the Skill/Agent tools).
- **git ≥ 2.5** — `forge-worktree.sh` uses `git worktree`.
- **GitHub CLI (`gh`)**, authenticated (`gh auth login`) — issues, PRs, inline review
  comments and threaded replies go through `gh`.
- A repo whose default branch is **`master`** (the worktree script branches off
  `master`; rename in `scripts/forge-worktree.sh` if yours is `main`).
- *(optional)* **graphify** — Phase 6 runs `graphify update .` to refresh a knowledge
  graph. If `graphify` isn't installed, forge notes it and continues.

---

## Adapting it to your project

A couple of phases reference conventions from the repo this was extracted from —
adjust them to taste:

- **Build checks.** The `/tdd` build contract runs Flutter checks (`flutter analyze`,
  `flutter test`, golden tests). Swap these for your stack's test/lint commands in
  `skills/forge/PLAYBOOK.md` (the subagent build + fix prompt templates).
- **Default branch.** `scripts/forge-worktree.sh` and Phase 6 assume `master`. Change
  to `main` if needed.
- **Triage labels.** `/to-issues` applies your tracker's labels; point it at your
  vocabulary.

---

## License

[MIT](LICENSE) © Hamza Sahin
