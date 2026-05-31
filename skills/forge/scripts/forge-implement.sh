#!/usr/bin/env bash
# forge-implement.sh — run a forge CLI implementer engine (cursor | codex) headlessly,
# fully autonomously, from a prompt held in a FILE. The main agent never hand-builds the
# CLI command line (that caused zsh word-splitting / quoting / EXIT=127 bugs); it writes
# the build/fix prompt to a .md file and calls this script. We assemble argv with bash
# arrays (no unquoted ${VAR:+…} word-splitting), wrap a portable timeout, and emit a
# machine-parseable receipt block as the LAST lines of stdout.
#
# Usage:
#   bash forge-implement.sh \
#     --engine   cursor|codex \
#     --workspace <dir> \              # the git worktree the agent edits (absolute)
#     --prompt-file <path.md> \        # the full build/fix prompt; read from disk, never inlined
#     [--mode    build|fix] \          # default build; fix resumes the build session
#     [--model   <model>] \            # engine-specific id; omit/"" = that engine's default
#     [--session <id>] \               # cursor fix: resume this session id (else --continue)
#     [--timeout <seconds>] \          # default 3600; 0 disables the timeout wrapper
#     [--out     <receipt-file>] \     # where the agent's final message lands (default: mktemp)
#     [--log-dir <dir>]                # where stdout/stderr logs land (default: mktemp -d)
#
# Output — the LAST lines of stdout are always this block (parse from the tail):
#   ===FORGE-IMPLEMENT===
#   ENGINE=<cursor|codex>
#   MODE=<build|fix>
#   EXIT=<cli exit code>            # 124 = timed out
#   STATUS=<ok|fail>
#   SESSION=<session id or empty>   # feed back as --session on the cursor fix round
#   RECEIPT_FILE=<path>            # contains the agent's final message (the receipt)
#   STDOUT_LOG=<path>
#   STDERR_LOG=<path>
# The receipt CONTENTS are printed above the block between RECEIPT markers.
set -euo pipefail

die() { echo "forge-implement: $*" >&2; exit 2; }

engine="" workspace="" prompt_file="" mode="build" model="" session="" timeout_s="3600" out="" log_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --engine)      engine="${2:-}"; shift 2 ;;
    --workspace)   workspace="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --mode)        mode="${2:-}"; shift 2 ;;
    --model)       model="${2:-}"; shift 2 ;;
    --session)     session="${2:-}"; shift 2 ;;
    --timeout)     timeout_s="${2:-}"; shift 2 ;;
    --out)         out="${2:-}"; shift 2 ;;
    --log-dir)     log_dir="${2:-}"; shift 2 ;;
    -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             die "unknown arg: $1" ;;
  esac
done

# --- validate ---------------------------------------------------------------
case "$engine" in cursor|codex) ;; *) die "engine must be cursor or codex (got '$engine')";; esac
case "$mode"   in build|fix)    ;; *) die "mode must be build or fix (got '$mode')";; esac
[ -n "$workspace" ] && [ -d "$workspace" ] || die "workspace dir missing or not a dir: '$workspace'"
[ -n "$prompt_file" ] && [ -s "$prompt_file" ] || die "prompt-file missing or empty: '$prompt_file'"
case "$timeout_s" in ''|*[!0-9]*) die "timeout must be an integer (seconds): '$timeout_s'";; esac

bin="$engine"; [ "$engine" = cursor ] && bin="cursor-agent"
command -v "$bin" >/dev/null 2>&1 || die "'$bin' not on PATH — preflight should have caught this"

out="${out:-$(mktemp "${TMPDIR:-/tmp}/forge-receipt-XXXXXX")}"
log_dir="${log_dir:-$(mktemp -d "${TMPDIR:-/tmp}/forge-impl-XXXXXX")}"
: > "$out"
stdout_log="$log_dir/stdout.log"; stderr_log="$log_dir/stderr.log"

# --- portable timeout wrapper (the original bug: unquoted ${TO:+…} under zsh) ----------
# Build a real argv array; never rely on word-splitting. timeout is optional (macOS lacks
# it by default — gtimeout from coreutils is the common alias).
timeout_prefix=()
if [ "$timeout_s" != "0" ]; then
  if command -v timeout >/dev/null 2>&1;  then timeout_prefix=(timeout "$timeout_s")
  elif command -v gtimeout >/dev/null 2>&1; then timeout_prefix=(gtimeout "$timeout_s")
  else echo "forge-implement: no timeout/gtimeout on PATH — running without a time limit" >&2
  fi
fi

# --- assemble the engine command as an array -------------------------------------------
cmd=()
case "$engine" in
  cursor)
    cmd=(cursor-agent -p --force --trust --workspace "$workspace" --output-format json)
    [ -n "$model" ] && cmd+=(--model "$model")
    if [ "$mode" = fix ]; then
      if [ -n "$session" ]; then cmd+=(--resume "$session"); else cmd+=(--continue); fi
    fi
    ;;
  codex)
    # `codex exec resume` takes NO --cd (it remembers the session cwd), so for a fix we cd in.
    if [ "$mode" = fix ]; then
      cd "$workspace"
      cmd=(codex exec resume)
      if [ -n "$session" ]; then cmd+=("$session"); else cmd+=(--last); fi
      cmd+=(--dangerously-bypass-approvals-and-sandbox --output-last-message "$out")
    else
      cmd=(codex exec --dangerously-bypass-approvals-and-sandbox --cd "$workspace" --output-last-message "$out")
    fi
    [ -n "$model" ] && cmd+=(--model "$model")
    ;;
esac

# --- run: prompt comes from the FILE via stdin (no inlining, no ARG_MAX, no quoting) ----
# Do NOT let a non-zero CLI exit abort the script — capture it.
set +e
"${timeout_prefix[@]}" "${cmd[@]}" < "$prompt_file" > "$stdout_log" 2> "$stderr_log"
rc=$?
set -e

# --- read the receipt + session per engine ---------------------------------------------
is_error=""
if [ "$engine" = cursor ]; then
  # cursor emits ONE JSON object on success: {result, session_id, is_error, …}.
  # Extract with python3 (no jq dependency); write .result to the receipt file.
  if command -v python3 >/dev/null 2>&1; then
    eval "$(python3 - "$stdout_log" "$out" <<'PY'
import json, sys
log, outf = sys.argv[1], sys.argv[2]
raw = open(log, encoding='utf-8', errors='replace').read().strip()
obj = None
for line in reversed(raw.splitlines()):
    line = line.strip()
    if line.startswith('{') and line.endswith('}'):
        try: obj = json.loads(line); break
        except Exception: pass
if obj is None:
    try: obj = json.loads(raw)
    except Exception: obj = {}
res = obj.get('result', '')
open(outf, 'w', encoding='utf-8').write(res if isinstance(res, str) else json.dumps(res))
def sh(v): return str(v).replace("'", "'\\''")
print("SESSION='%s'"  % sh(obj.get('session_id') or ''))
print("is_error='%s'" % sh(str(obj.get('is_error')).lower()))
PY
)"
  else
    echo "forge-implement: python3 not found — cannot parse cursor JSON; using raw stdout as receipt" >&2
    cp "$stdout_log" "$out"; SESSION=""; is_error="unknown"
  fi
else
  # codex: --output-last-message already wrote the final message to $out. Session id is not
  # surfaced without --json; the fix round resumes via --last, so SESSION stays empty.
  SESSION=""
fi
SESSION="${SESSION:-}"

# --- decide STATUS ----------------------------------------------------------------------
status="fail"
if [ "$rc" -eq 0 ] && [ -s "$out" ]; then
  if [ "$engine" = cursor ]; then
    [ "$is_error" = "false" ] && status="ok"   # cursor: require is_error==false
  else
    status="ok"                                # codex: exit 0 + non-empty receipt
  fi
fi

# --- emit ------------------------------------------------------------------------------
echo "===RECEIPT==="
cat "$out"
echo
echo "===END RECEIPT==="
echo "===FORGE-IMPLEMENT==="
echo "ENGINE=$engine"
echo "MODE=$mode"
echo "EXIT=$rc"
echo "STATUS=$status"
echo "SESSION=$SESSION"
echo "RECEIPT_FILE=$out"
echo "STDOUT_LOG=$stdout_log"
echo "STDERR_LOG=$stderr_log"
