# SCM command recipes — GitHub (`gh`) vs GitLab (`glab`)

forge reads `cli` from `.yaah/config.yml` and uses the matching column below. Terminology:
GitHub **PR** ≙ GitLab **MR**; GitHub issue `#N`, GitLab issue `#N` and MR `!N`.
`{owner}/{repo}` ≙ GitLab `{project}` (URL-encoded path or numeric ID; `glab` infers it
from the remote, so the plain `glab` subcommands rarely need it).

## Issues

| Action | GitHub (`gh`) | GitLab (`glab`) |
|---|---|---|
| Create | `gh issue create --title T --body B [--label L]` | `glab issue create --title T --description B [--label L]` |
| Comment | `gh issue comment N --body B` | `glab issue note N -m B` |
| View | `gh issue view N` | `glab issue view N` |
| List labels | `gh label list` | `glab label list` |

Capture the created issue's number/URL from the command output either way.

## Pull / Merge requests

| Action | GitHub (`gh`) | GitLab (`glab`) |
|---|---|---|
| Create, linked to issue | `gh pr create --base BASE --head BRANCH --title T --body "Closes #N"` | `glab mr create --source-branch BRANCH --target-branch BASE --title T --description "Closes #N"` |
| Merge | `gh pr merge N` (per repo convention: `--squash`/`--merge`/`--rebase`) | `glab mr merge N` (add `--squash`/`--rebase` per convention) |
| View | `gh pr view N` | `glab mr view N` |

"Closes #N" in the PR/MR body auto-links and auto-closes the issue on both platforms.

## Inline review comments + threaded replies

The review loop posts findings on the diff and replies on each thread when fixed.

**GitHub** — REST via `gh api`:
- List existing comments: `gh api repos/{owner}/{repo}/pulls/{pr}/comments`
- Post an inline comment (capture `.id`):
  ```
  gh api repos/{owner}/{repo}/pulls/{pr}/comments \
    -f body="finding" -f commit_id="$SHA" -f path="src/foo.ts" -F line=42 -f side=RIGHT --jq '.id'
  ```
- Reply on that thread:
  ```
  gh api repos/{owner}/{repo}/pulls/{pr}/comments/{comment_id}/replies -f body="resolved: …"
  ```

**GitLab** — Discussions via `glab api` (a "discussion" is a thread; reply by adding a note to it):
- Post a diff-positioned discussion (capture `.id`):
  ```
  glab api -X POST "projects/:id/merge_requests/{mr_iid}/discussions" \
    -f body="finding" \
    -f position[position_type]=text \
    -f position[new_path]="src/foo.ts" -f position[new_line]=42 \
    -f position[base_sha]="$BASE_SHA" -f position[head_sha]="$HEAD_SHA" -f position[start_sha]="$BASE_SHA"
  ```
  (`glab` expands `:id` to the project from the remote. Get the SHAs from
  `glab api projects/:id/merge_requests/{mr_iid}/versions`.)
- Reply on that thread:
  ```
  glab api -X POST "projects/:id/merge_requests/{mr_iid}/discussions/{discussion_id}/notes" -f body="resolved: …"
  ```
- If diff-position params are unavailable, fall back to a plain MR note
  (`glab mr note {mr_iid} -m "…"`) and reference the file:line in the text — still
  one comment per finding, just not anchored to the diff line.

## Auth / preflight

| | GitHub | GitLab |
|---|---|---|
| Installed? | `gh --version` | `glab --version` |
| Authed? | `gh auth status` | `glab auth status` |

A missing CLI or failed auth is a hard blocker — surface it and stop.
