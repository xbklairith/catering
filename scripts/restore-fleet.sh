#!/bin/zsh
# Bring the fleet back from a save-fleet.sh snapshot after a reboot or a herdr server
# restart. For each saved agent:
#   pane runs the saved session with the saved flags   -> skip
#   pane runs it without them (herdr's bare restore)   -> relaunch with the saved flags
#                                                         (restart-idle.sh: same safety checks)
#   pane is an empty shell in the saved directory      -> start the agent, resuming its session
#   pane gone or in another directory                  -> new workspace, then start it there
#   pane runs another session                          -> warn, leave it
#   saved from outside herdr                           -> print the command to resume by hand
# The pane running this script is never relaunched: if it is an empty shell, the agent saved
# there starts in it last (exec); if it runs Claude without its saved flags, the line to fix
# it with restart-self.sh is printed. Safe to re-run. A real run (not --dry-run) marks the
# fleet restored, which lets save-fleet.sh save again after a reboot.
#
# Usage: restore-fleet.sh [--dry-run] [SNAPSHOT]   (default: the newest snapshot)
set -uo pipefail
source ${0:A:h}/lib.sh
require herdr jq
zmodload zsh/datetime zsh/stat

dry=0; [[ ${1:-} == --dry-run ]] && { dry=1; shift; }
file=${1:-$(snapshot_latest)}
[[ -n $file && -f $file ]] || { echo "no snapshot found; save-fleet.sh makes one" >&2; exit 1; }
self=${HERDR_PANE_ID:-}
typeset -a own; owncwd=""
mtime=$(zstat +mtime "$file")
echo "snapshot ${file:t}, taken $(( (EPOCHSECONDS - mtime) / 3600 ))h $(( (EPOCHSECONDS - mtime) % 3600 / 60 ))m ago"

# "SID|FLAGS" of the KIND process in PANE (SID "?" when unknown), or nothing
running_session() {
  local proc pid sid; local -a av flags
  proc=$(herdr pane process-info --pane "$1" 2>/dev/null | jq -c --arg k "$2" '[.result.process_info.foreground_processes[] |
           select(((.argv0 // .argv[0] // "") | split("/") | last) == $k)][0] // {}')
  pid=$(jq -r '.pid // empty' <<<"$proc")
  [[ -n $pid ]] || return 0
  av=("${(@f)$(jq -r '.argv // [] | .[1:][]' <<<"$proc")}"); av=(${av:#})
  split_session sid flags "$2" "${av[@]}"
  [[ $2 == claude && -f $HOME/.claude/sessions/$pid.json ]] && sid=$(jq -r '.sessionId // empty' "$HOME/.claude/sessions/$pid.json")
  print -r -- "${sid:-?}|${(j: :)${(@q-)flags}}"
}

# the command that resumes SID: usage resume_argv OUT KIND SID FLAG...
resume_argv() {
  local __o=$1 __k=$2 __s=$3; shift 3
  case $__k in
    claude) set -A $__o "$__k" "$@" ${__s:+--resume} ${__s:+$__s} ;;
    agy)    set -A $__o "$__k" "$@" ${__s:+--conversation=$__s} ;;
    *)      set -A $__o "$__k" "$@" ;;
  esac
}

start_agent() {   # PANE NAME ARGV...
  local pane=$1 name=$2 out; shift 2
  if (( dry )); then echo "$pane WOULD start $name: ${(j: :)${(@q-)@}}"; return; fi
  if out=$(herdr agent start "$name" --kind "$1" --pane "$pane" --timeout 120000 -- "${@:2}" 2>&1 </dev/null); then
    echo "$pane OK $name"
  elif [[ $out == *agent_not_ready* ]]; then
    echo "$pane NEEDS YOU $name started but waits at a startup prompt: herdr pane read $pane"
  elif out=$(herdr agent start "$(agent_name "$name-${pane//:/}")" --kind "$1" --pane "$pane" --timeout 120000 -- "${@:2}" 2>&1 </dev/null); then
    echo "$pane OK $name (renamed: the name was taken)"
  else
    echo "$pane FAIL $name: ${out//$'\n'/ }"
  fi
}

while IFS='|' read -r -u 3 pane label name kind cwd sid flags; do
  [[ -z $pane || $pane == \#* ]] && continue
  saved=(${(Q)${(z)flags}})
  resume_argv cmd "$kind" "$sid" "${saved[@]}"
  run="" cwd_ok=0
  if [[ $pane != - ]]; then
    [[ $(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.cwd // empty') == "$cwd" ]] && cwd_ok=1
    (( cwd_ok )) && run=$(running_session "$pane" "$kind")
  fi
  run_sid=${run%%|*} run_flags=${run#*|}
  case $(restore_action "$pane" "$self" $cwd_ok "$run_sid" "$sid" "$run_flags" "$flags" "$kind") in
    manual)     echo "outside herdr: $name, resume by hand: cd ${(q-)cwd} && ${(j: :)${(@q-)cmd}}" ;;
    skip)       echo "$pane SKIP $name runs with its saved flags" ;;
    self-skip)  echo "$pane SKIP $name (this session)" ;;
    self-flags) echo "$pane SELF this session runs without its saved flags; fix: ${0:A:h}/restart-self.sh ${(j: :)${(@q-)saved}}" ;;
    self-start) own=("${cmd[@]}"); owncwd=$cwd ;;
    other)      echo "$pane WARN runs another $kind session ($run_sid), not $sid; left alone" ;;
    differs)    echo "$pane WARN $name runs with other flags than saved; $kind can't be relaunched here" ;;
    reflag)
      if (( dry )); then echo "$pane WOULD relaunch $name with its saved flags: ${(j: :)${(@q-)cmd}}"
      else ${0:A:h}/restart-idle.sh "$pane" -- "${saved[@]}" | grep -v '^latest installed'; fi ;;
    start)      start_agent "$pane" "$name" "${cmd[@]}" ;;
    new)
      if (( dry )); then echo "$pane gone or moved: WOULD open workspace '$label' in $cwd"; start_agent "(new)" "$name" "${cmd[@]}"
      else
        target=$(herdr workspace create --cwd "$cwd" --label "$label" --no-focus | jq -r '.result.root_pane.pane_id // empty')
        if [[ -n $target ]]; then echo "$pane gone or moved: opened workspace '$label' pane $target"; start_agent "$target" "$name" "${cmd[@]}"
        else echo "$pane FAIL could not open a workspace in $cwd"; fi
      fi ;;
  esac
done 3< "$file"
(( dry )) || { mkdir -p "$FLEET_SNAPSHOTS" && touch "$FLEET_RESTORED"; }   # lets save-fleet.sh save again after a reboot

echo "Session-only scheduled tasks come back with --resume but expire 7 days after they were made: check CronList in sessions that had some before re-creating any."
if (( ${#own} )); then
  if (( dry )); then echo "$self (this pane) WOULD exec: ${(j: :)${(@q-)own}}"
  else echo "$self: starting ${own[1]} here"; cd "$owncwd" && exec "${own[@]}"; fi
fi
