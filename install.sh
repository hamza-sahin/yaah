#!/usr/bin/env bash
# install.sh — copy the yaah skills into a Claude Code skills directory.
#
#   ./install.sh                      # install globally to ~/.claude/skills
#   ./install.sh --project <repo>     # install to <repo>/.claude/skills
#
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

echo "yaah installed to: $dest"
echo "Skills:"
for d in "$dest"/forge "$dest"/grill-with-docs "$dest"/to-issues "$dest"/handoff "$dest"/tdd "$dest"/thermo-nuclear-code-quality-review; do
  [ -d "$d" ] && echo "  - $(basename "$d")"
done
echo "Start a new Claude Code session and run /forge to use it."
