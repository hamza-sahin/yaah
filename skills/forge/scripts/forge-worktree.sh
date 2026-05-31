#!/usr/bin/env bash
# forge-worktree.sh — isolated git worktrees so many /forge runs go in parallel
# without touching each other or master.
#
# Usage (call via `bash`, so it works regardless of the executable bit):
#   bash forge-worktree.sh create <slug>   # new worktree off latest master; prints receipt
#   bash forge-worktree.sh remove <path>   # tear a worktree down (after merge)
#
# create prints two machine-parseable lines as the LAST two lines of stdout:
#   WORKTREE=/abs/path/to/worktree
#   BRANCH=feat/<slug>-<unique>
# Everything else (git chatter) goes to stderr.
set -euo pipefail

die() { echo "forge-worktree: $*" >&2; exit 1; }

cmd="${1:-}"
[ -n "$cmd" ] || die "usage: forge-worktree.sh {create <slug> | remove <path>}"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
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

case "$cmd" in
  create)
    slug="$(slugify "${2:-forge}")"
    [ -n "$slug" ] || slug="forge"

    # Base on the LATEST master. Prefer origin/master when a remote exists so
    # parallel runs all branch from the same up-to-date point. A failed fetch
    # (offline / transient / a concurrent run racing the shared .git) must NOT
    # abort when a usable base already exists — fall back, loudly.
    base="master"
    if git remote get-url origin >/dev/null 2>&1; then
      if git fetch --quiet origin master 2>/dev/null; then
        base="origin/master"
      elif git rev-parse --verify --quiet origin/master >/dev/null; then
        echo "forge-worktree: fetch failed; using cached origin/master" >&2
        base="origin/master"
      elif git rev-parse --verify --quiet master >/dev/null; then
        echo "forge-worktree: fetch failed; using local master" >&2
        base="master"
      else
        die "git fetch failed and no origin/master or local master ref"
      fi
    else
      git rev-parse --verify --quiet master >/dev/null || die "no 'master' branch found"
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
