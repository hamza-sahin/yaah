#!/usr/bin/env bash
# install.sh — copy the yaah skills into a Claude Code skills directory.
#
#   ./install.sh                      # install globally to ~/.claude/skills
#   ./install.sh --project <repo>     # install to <repo>/.claude/skills
#
# After installing, open Claude Code in your repo and run /setup-yaah once to
# generate that repo's .yaah/config.yml (tracker, default branch, checks). Then
# /forge <task> drives the pipeline.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
src="$here/skills"
[ -d "$src" ] || { echo "install: skills/ not found next to install.sh" >&2; exit 1; }

dest="$HOME/.claude/skills"
if [ "${1:-}" = "--project" ]; then
  [ -n "${2:-}" ] || { echo "install: --project needs a repo path" >&2; exit 1; }
  dest="${2%/}/.claude/skills"
fi

mkdir -p "$dest"
cp -R "$src/"* "$dest/"
chmod +x "$dest/forge/scripts/forge-worktree.sh" 2>/dev/null || true
chmod +x "$dest/systematic-debugging/find-polluter.sh" 2>/dev/null || true

echo "yaah installed to: $dest"
echo "Skills:"
for d in "$dest"/setup-yaah "$dest"/forge "$dest"/grill-with-docs "$dest"/to-prd "$dest"/to-issues "$dest"/handoff "$dest"/tdd "$dest"/systematic-debugging "$dest"/spec-compliance-review "$dest"/thermo-nuclear-code-quality-review "$dest"/receiving-code-review "$dest"/writing-skills; do
  [ -d "$d" ] && echo "  - $(basename "$d")"
done
echo
echo "Next:"
echo "  1. Open Claude Code in your repo."
echo "  2. Run /setup-yaah once   (creates .yaah/config.yml for this repo)."
echo "  3. Run /forge <task>      (drives the pipeline)."
