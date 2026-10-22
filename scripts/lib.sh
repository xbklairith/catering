# Shared helpers for the fleet scripts. Source it: source ${0:A:h}/lib.sh
# Works on macOS and Linux (zsh). Needs: herdr, jq, claude.

FLEET_OS=$(uname -s)
FLEET_HOME=${${(%):-%x}:A:h:h}                  # repo root (symlinks resolved)
FLEET_PROJECTS=${FLEET_PROJECTS:-${FLEET_HOME:h}} # projects dir, default: repo's parent
FLEET_LOCAL=$FLEET_HOME/local                    # gitignored machine notes + scripts

# exit with a message unless every named command is on PATH
require() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing} )) && { echo "missing required command(s): ${missing[*]}" >&2; exit 127; }
  return 0
}

# direct children of a pid. macOS pgrep hides the caller's own ancestors unless -a;
# on Linux -a means "print the command line", so it must not be passed there.
child_pids() {
  if [[ $FLEET_OS == Darwin ]]; then pgrep -a -P "$1"; else pgrep -P "$1"; fi
}

# herdr agent names: [a-z][a-z0-9_-]{0,31}. Lowercase first, then replace the rest.
agent_name() {
  local n=${${(L)1}//[^a-z0-9_-]/-}
  [[ $n == [a-z]* ]] || n=a-$n
  print -r -- ${n:0:32}
}

# The claude process in a pane as JSON ({} if none). herdr sends the program as argv0 in
# older versions and only as argv[0] in newer ones; argv[0] may be a full path. (name is
# no use on macOS: Claude Code sets its process title to its version.)
pane_claude_proc() {
  herdr pane process-info --pane "$1" | jq -c '[.result.process_info.foreground_processes[] |
    select(((.argv0 // .argv[0] // "") | split("/") | last) == "claude")][0] // {}'
}

# pid of the claude process in a pane, or empty
pane_claude_pid() { pane_claude_proc "$1" | jq -r '.pid // empty'; }

# original argv of the claude process in a pane, minus the program name, one arg per line
pane_claude_args() { pane_claude_proc "$1" | jq -r '.argv // [] | .[1:][]'; }

# Fill the named array with args minus --resume/-r [id], --resume=*, --continue/-c.
# usage: strip_resume out_array_name arg...
strip_resume() {
  local __out=$1; shift
  local -a kept; local skip=0 a
  for a in "$@"; do
    if (( skip )); then skip=0; [[ $a == -* ]] || continue; fi
    case $a in
      --resume|-r) skip=1 ;;
      --resume=*|--continue|-c) ;;
      *) kept+=("$a") ;;
    esac
  done
  set -A $__out "${kept[@]}"
}

# Bash-tool / Monitor shells under a claude pid (MCP servers are not matched)
job_shells() {
  local k
  for k in $(child_pids "$1"); do
    [[ $(ps -o command= -p "$k" 2>/dev/null) == *shell-snapshots* ]] && print -r -- "$k"
  done
}

# Text the user has typed but not sent in a Claude pane's input box ("" if empty).
# Returns 1 when the pane can't be read or shows no input box: callers must treat that as
# "unknown, don't restart", never as an empty box.
# Claude Code draws its prompt suggestion and the fresh-session 'Try "..."' placeholder
# dim (ESC[2m), so dim text counts as empty; only normally styled text is a draft.
pane_draft() {
  setopt localoptions extendedglob
  local screen line esc=$'\e'
  screen=$(herdr pane read "$1" --format ansi) || return 1
  line=$(print -r -- "$screen" | grep -a -E "^(${esc}\[[0-9;]*m)*❯" | tail -1)
  [[ -n $line ]] || return 1
  line=${line//${esc}\[2m[^${esc}]#/}        # drop dim spans (suggestions)
  line=${line//${esc}\[[0-9;]#m/}            # drop the remaining styling
  line=${line#❯}
  line=${line//$'\xc2\xa0'/ }                # no-break spaces, as UTF-8 bytes: works in C locale too
  line=${${line##[[:space:]]##}%%[[:space:]]##}
  [[ $line == 'Try "'* ]] && line=""
  print -r -- "$line"
}

# Why /exit left a Claude pane open: "feedback" (unsent feedback draft: Esc DISCARDS it, so
# never press it; the user decides), "scheduled" (Background work is running: Esc cancels
# the exit, tasks keep running), or "" (unknown). The screen also holds old conversation
# text, so feedback is checked first, anywhere (a false hit only means "ask the user"), and
# scheduled only in the bottom lines where the dialog is drawn.
# (Captured, not piped into grep -q: under pipefail an early grep exit fails the pipeline.)
exit_blocker() {
  local all bottom
  all=$(herdr pane read "$1"); bottom=$(herdr pane read "$1" --lines 30)
  if [[ $all == *'unsent feedback draft'* ]]; then print feedback
  elif [[ $bottom == *'Background work is running'* ]]; then print scheduled
  fi
}
