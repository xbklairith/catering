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
strip_resume() { local __sid; split_session __sid "$1" claude "${@:2}"; }

# Split an agent's launch args into its session id and the rest of its flags.
#   claude: --resume ID, -r ID, --resume=ID (--continue/-c are dropped too)
#   agy:    --conversation ID, --conversation=ID
#   other kinds: no id, every arg stays
# usage: split_session SID_VAR FLAGS_ARRAY KIND ARG...   (locals are __-prefixed so the
# caller's variable names can't be shadowed)
split_session() {
  local __sidv=$1 __flagsv=$2 __kind=$3 __id="" __a __next=0 __opt=""
  local -a __kept
  shift 3
  case $__kind in claude) __opt=--resume ;; agy) __opt=--conversation ;; esac
  for __a in "$@"; do
    if (( __next )); then __next=0; [[ $__a == -* ]] || { __id=$__a; continue; }; fi
    if [[ -n $__opt && ( $__a == "$__opt" || ( $__kind == claude && $__a == -r ) ) ]]; then __next=1
    elif [[ -n $__opt && $__a == "$__opt="* ]]; then __id=${__a#*=}
    elif [[ $__kind == claude && ( $__a == --continue || $__a == -c ) ]]; then :
    else __kept+=("$__a"); fi
  done
  : ${(P)__sidv::=$__id}
  set -A $__flagsv "${__kept[@]}"
}

# --- fleet snapshots (save-fleet.sh / restore-fleet.sh) ---
# One line per agent: pane|workspace label|agent name|kind|cwd|session id|flags, flags
# zsh-quoted and last (so a | inside them is safe). Pane "-" = a Claude session outside herdr.
FLEET_SNAPSHOTS=${FLEET_SNAPSHOTS:-$FLEET_LOCAL/snapshots}

# usage: snapshot_row PANE LABEL NAME KIND CWD SID FLAG...
snapshot_row() { print -r -- "${(j:|:)@[1,6]}|${(j: :)${(@q-)@[7,-1]}}"; }

# newest snapshot file, or nothing
snapshot_latest() { print -r -- $FLEET_SNAPSHOTS/fleet-*.tsv(Nom[1]); }

# Sessions that had flags in PREV and run with none in NEW (same session id): the mark of
# herdr's own restore, which relaunches Claude as a bare `claude --resume <id>`. Prints
# "SID (name)" per session; returns 0 if there are any.
# usage: snapshot_clobbers PREV_ROWS NEW_ROWS
snapshot_clobbers() {
  local -A now; local line sid flags name found=1
  local -a f
  for line in "${(@f)2}"; do
    f=("${(@s:|:)line}"); [[ -n ${f[6]:-} ]] && now[${f[6]}]=${(j:|:)f[7,-1]}
  done
  for line in "${(@f)1}"; do
    f=("${(@s:|:)line}"); sid=${f[6]:-}; name=${f[3]:-}; flags=${(j:|:)f[7,-1]}
    [[ -n $sid && -n $flags && ${+now[$sid]} == 1 && -z ${now[$sid]} ]] && { print -r -- "$sid ($name)"; found=0; }
  done
  return $found
}

# What restore-fleet.sh does with one saved agent; the caller gathers the facts.
# usage: restore_action PANE SELF_PANE CWD_MATCH RUN_SID SAVED_SID RUN_FLAGS SAVED_FLAGS KIND
#   PANE "-": saved from outside herdr. CWD_MATCH: 1 when the pane exists in the saved dir.
#   RUN_SID: session running in the pane ("" = none). Flags as stored (zsh-quoted).
# prints: manual | self-start | self-skip | self-flags | new | start | other | skip
#         | reflag (relaunch with the saved flags) | differs (flags differ, kind can't relaunch)
restore_action() {
  local pane=$1 self=$2 cwd_ok=$3 run_sid=$4 sid=$5 run_flags=$6 flags=$7 kind=$8 same=0
  [[ $pane == - ]] && { print manual; return; }
  [[ ${(j:\0:)${(Q)${(z)run_flags}}} == ${(j:\0:)${(Q)${(z)flags}}} ]] && same=1
  if [[ $pane == "$self" ]]; then
    if [[ -z $run_sid ]]; then print self-start
    elif (( same )); then print self-skip
    else print self-flags; fi
    return
  fi
  (( cwd_ok )) || { print new; return; }
  [[ -z $run_sid ]] && { print start; return; }
  [[ $run_sid != "$sid" ]] && { print other; return; }
  if (( same )); then print skip
  elif [[ $kind == claude ]]; then print reflag
  else print differs; fi
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
