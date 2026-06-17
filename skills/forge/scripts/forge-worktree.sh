#!/usr/bin/env bash
# forge-worktree.sh — isolated git worktrees so many /forge runs go in parallel
# without touching each other or the base branch.
#
# Usage (call via `bash`, so it works regardless of the executable bit):
#   bash forge-worktree.sh create <slug> [base-ref]  # new worktree off the base branch
#   bash forge-worktree.sh remove <path>             # tear a worktree down (after merge)
#
# Base branch resolution (stack-agnostic — no hardcoded main/master):
#   1. the optional <base-ref> argument (e.g. a blocker slice's branch)
#   2. $FORGE_BASE_BRANCH if set
#   3. the remote's default branch (origin/HEAD)
#   4. a local `main` or `master`, whichever exists
#   5. "main"
#
# create prints two machine-parseable lines as the LAST two lines of stdout:
#   WORKTREE=/abs/path/to/worktree
#   BRANCH=feat/<slug>-<unique>
# Everything else (git chatter) goes to stderr.
set -euo pipefail

die() { echo "forge-worktree: $*" >&2; exit 1; }

cmd="${1:-}"
[ -n "$cmd" ] || die "usage: forge-worktree.sh {create <slug> [base-ref] | remove <path>}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"

# Worktree-environment detection: if we're already inside a LINKED worktree
# (git-dir != git-common-dir), anchor new worktrees at the MAIN working tree
# (the parent of the common .git dir) so we never nest .forge-worktrees inside a
# worktree. In the main worktree the two dirs match and repo_root is used as-is.
git_dir="$(git rev-parse --git-dir 2>/dev/null || true)"
common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
  case "$common_dir" in /*) abs_common="$common_dir" ;; *) abs_common="$repo_root/$common_dir" ;; esac
  main_root="$(cd "$(dirname "$abs_common")" 2>/dev/null && pwd)" || main_root="$repo_root"
  # Submodule guard: a submodule's common dir lives under <super>/.git/modules/…;
  # in that case stay in this submodule rather than escaping to the superproject.
  case "$abs_common" in */.git/modules/*) main_root="$repo_root" ;; esac
  if [ "$main_root" != "$repo_root" ]; then
    echo "forge-worktree: inside a linked worktree; anchoring new worktrees at main root $main_root" >&2
    repo_root="$main_root"
  fi
fi
cd "$repo_root" || die "cannot cd to repo root: $repo_root"

slugify() {
  # Truncate + trailing-dash strip via bash param expansion (no `cut`: its early
  # pipe-close can SIGPIPE under pipefail and can leave a trailing dash).
  local s
  s=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//') || s=""
  s=${s:0:40}
  s=${s%-}
  printf '%s' "$s"
}

# Resolve the base branch NAME (not a ref) without assuming main/master.
detect_base_branch() {
  local b
  if [ -n "${FORGE_BASE_BRANCH:-}" ]; then printf '%s' "$FORGE_BASE_BRANCH"; return; fi
  b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^[^/]*/@@')" || true
  if [ -n "$b" ]; then printf '%s' "$b"; return; fi
  if git remote get-url origin >/dev/null 2>&1; then
    b="$(git remote show origin 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)" || true
    if [ -n "$b" ] && [ "$b" != "(unknown)" ]; then printf '%s' "$b"; return; fi
  fi
  local c
  for c in main master; do
    if git rev-parse --verify --quiet "$c" >/dev/null; then printf '%s' "$c"; return; fi
  done
  printf 'main'
}

case "$cmd" in
  create)
    slug="$(slugify "${2:-forge}")"
    [ -n "$slug" ] || slug="forge"
    base_override="${3:-}"

    if [ -n "$base_override" ]; then
      # Explicit base (e.g. a blocker slice's branch). Prefer the remote-tracking
      # ref when it exists; otherwise use the override as given.
      if git rev-parse --verify --quiet "origin/$base_override" >/dev/null; then
        base="origin/$base_override"
      elif git rev-parse --verify --quiet "$base_override" >/dev/null; then
        base="$base_override"
      else
        die "base-ref '$base_override' not found locally or on origin"
      fi
    else
      bb="$(detect_base_branch)"
      # Base on the LATEST tip of the base branch. Prefer origin/<bb> when a remote
      # exists so parallel runs all branch from the same up-to-date point. A failed
      # fetch (offline / transient / a concurrent run racing the shared .git) must
      # NOT abort when a usable base already exists — fall back, loudly.
      if git remote get-url origin >/dev/null 2>&1; then
        if git fetch --quiet origin "$bb" 2>/dev/null; then
          base="origin/$bb"
        elif git rev-parse --verify --quiet "origin/$bb" >/dev/null; then
          echo "forge-worktree: fetch failed; using cached origin/$bb" >&2
          base="origin/$bb"
        elif git rev-parse --verify --quiet "$bb" >/dev/null; then
          echo "forge-worktree: fetch failed; using local $bb" >&2
          base="$bb"
        else
          die "git fetch failed and no origin/$bb or local $bb ref"
        fi
      else
        git rev-parse --verify --quiet "$bb" >/dev/null || die "no '$bb' branch found"
        base="$bb"
      fi
    fi

    # mktemp -d reserves a kernel-unique dir name atomically, so simultaneous
    # runs (even same-second, same-process) can never collide on path or branch.
    wt_base="$(dirname "$repo_root")/.forge-worktrees"
    mkdir -p "$wt_base" || die "cannot create worktree base dir: $wt_base"
    wt_path="$(mktemp -d "${wt_base}/${slug}-XXXXXXXX")" || die "mktemp -d failed"
    branch="feat/$(basename "$wt_path")"

    # git accepts an existing EMPTY dir as the worktree target.
    git worktree add -b "$branch" "$wt_path" "$base" 1>&2 \
      || die "git worktree add failed (branch=$branch base=$base)"

    echo "WORKTREE=${wt_path}"
    echo "BRANCH=${branch}"
    ;;
  remove)
    wt_path="${2:-}"
    [ -n "$wt_path" ] || die "remove needs a worktree path"
    if [ -d "$wt_path" ]; then
      branch="$(git -C "$wt_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      git worktree remove "$wt_path" --force || die "git worktree remove failed: $wt_path"
      # Called only post-merge, so dropping the feature branch is safe hygiene.
      case "$branch" in
        feat/*) git branch -D "$branch" >/dev/null 2>&1 || true ;;
      esac
    else
      echo "forge-worktree: $wt_path already gone; pruning admin entries" >&2
    fi
    git worktree prune >/dev/null 2>&1 || true
    echo "REMOVED=${wt_path}"
    ;;
  *)
    die "unknown command: $cmd (use create|remove)"
    ;;
esac
