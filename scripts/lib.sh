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

# pid of the claude process in a pane, or empty
pane_claude_pid() {
  herdr pane process-info --pane "$1" |
    jq -r '[.result.process_info.foreground_processes[] | select(.argv0=="claude")][0].pid // empty'
}

# original argv of the claude process in a pane, minus the program name, one arg per line
pane_claude_args() {
  herdr pane process-info --pane "$1" |
    jq -r '[.result.process_info.foreground_processes[] | select(.argv0=="claude")][0].argv // [] | .[1:][]'
}

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
# The fresh-session placeholder 'Try "..."' counts as empty.
pane_draft() {
  setopt localoptions extendedglob
  local line
  line=$(herdr pane read "$1" | grep -E '^❯' | tail -1)
  line=${line#❯}
  line=${line//$'\xc2\xa0'/ }                # no-break spaces, as UTF-8 bytes: works in C locale too
  line=${${line##[[:space:]]##}%%[[:space:]]##}
  [[ $line == 'Try "'* ]] && line=""
  print -r -- "$line"
}
