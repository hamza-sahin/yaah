#!/usr/bin/env bash
# install.sh — copy the yaah skills + forge agents into a Claude Code directory.
#
#   ./install.sh                      # install globally to ~/.claude/{skills,agents}
#   ./install.sh --project <repo>     # install to <repo>/.claude/{skills,agents}
#
# After installing, open Claude Code in your repo and run /setup-yaah once to
# generate that repo's .yaah/config.yml (tracker, default branch, checks). Then
# /forge <task> drives the pipeline.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/skills"
[ -d "$src" ] || { echo "install: skills/ not found next to install.sh" >&2; exit 1; }

base="$HOME/.claude"
if [ "${1:-}" = "--project" ]; then
  [ -n "${2:-}" ] || { echo "install: --project needs a repo path" >&2; exit 1; }
  base="${2%/}/.claude"
fi
dest="$base/skills"
agents_dest="$base/agents"

mkdir -p "$dest"
cp -R "$src/"* "$dest/"
chmod +x "$dest/forge/scripts/forge-worktree.sh" 2>/dev/null || true
chmod +x "$dest/systematic-debugging/find-polluter.sh" 2>/dev/null || true

# forge agents (claude engine): the implementer + the two reviewers. Canonical
# source lives in the setup-yaah skill so /setup-yaah can install them too.
agents_src="$src/setup-yaah/agents"
if [ -d "$agents_src" ]; then
  mkdir -p "$agents_dest"
  cp -R "$agents_src/"*.md "$agents_dest/"
fi

echo "yaah installed to: $base"
echo "Skills:"
for d in "$dest"/setup-yaah "$dest"/forge "$dest"/grill-with-docs "$dest"/to-prd "$dest"/to-issues "$dest"/handoff "$dest"/tdd "$dest"/systematic-debugging "$dest"/spec-and-quality-review "$dest"/receiving-code-review "$dest"/writing-skills; do
  [ -d "$d" ] && echo "  - $(basename "$d")"
done
echo "Agents (claude engine):"
for a in "$agents_dest"/implementer.md "$agents_dest"/per-round-reviewer.md "$agents_dest"/final-reviewer.md; do
  [ -f "$a" ] && echo "  - $(basename "$a" .md)"
done
echo
echo "Next:"
echo "  1. Open Claude Code in your repo."
echo "  2. Run /setup-yaah once   (creates .yaah/config.yml for this repo)."
echo "  3. Run /forge <task>      (drives the pipeline)."
