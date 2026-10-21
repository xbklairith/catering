#!/bin/zsh
# Restart idle/done Claude Code sessions in herdr panes so they pick up the latest installed
# version, resuming the same session ID with the same launch flags.
#
# Usage: restart-idle.sh [--dry-run] [PANE_ID...]
#   no panes  -> every claude pane that is idle/done and older than the installed version
#   PANE_ID   -> only those panes (still subject to the safety checks)
#
# Never touches: the pane running this script, panes that are working/blocked/unknown,
# sessions with a background shell (Bash run_in_background / Monitor), sessions with unsent
# text in the input box, and sessions whose /exit shows "Background work is running"
# (scheduled tasks) — that dialog is cancelled with Esc and the session keeps running.
# An "unsent feedback draft" dialog on /exit is left open for the user: Esc would discard it.
set -uo pipefail
source ${0:A:h}/lib.sh
require herdr jq claude

dry=0
[[ ${1:-} == --dry-run ]] && { dry=1; shift; }
latest=$(claude --version 2>/dev/null | awk '{print $1}')
self=${HERDR_PANE_ID:-}
explicit=$(( $# > 0 ))

restart_one() {
  local pane=$1 st pid meta sid ver name np draft
  local -a args flags
  [[ $pane == "$self" ]] && { echo "$pane SKIP (this session)"; return; }
  st=$(herdr agent list | jq -r --arg p "$pane" '.result.agents[] | select(.pane_id==$p and .agent=="claude") | .agent_status')
  [[ $st == idle || $st == done ]] || { echo "$pane SKIP status=${st:-no-claude}"; return; }
  pid=$(pane_claude_pid "$pane"); meta=$HOME/.claude/sessions/$pid.json
  [[ -n $pid && -f $meta ]] || { echo "$pane SKIP no session metadata"; return; }
  sid=$(jq -r .sessionId "$meta"); ver=$(jq -r .version "$meta")
  (( ! explicit )) && [[ $ver == "$latest" ]] && { echo "$pane SKIP already $ver"; return; }
  [[ -n $(job_shells "$pid") ]] && { echo "$pane SKIP background shell running (see stuck-loops.sh)"; return; }
  draft=$(pane_draft "$pane") || { echo "$pane SKIP input box not readable"; return; }
  [[ -n $draft ]] && { echo "$pane SKIP unsent input: ${draft:0:40}"; return; }
  args=("${(@f)$(pane_claude_args "$pane")}"); [[ -z ${args[1]:-} ]] && args=()
  strip_resume flags "${args[@]}"
  name=$(agent_name "$(jq -r .name "$meta")")
  if (( dry )); then echo "$pane WOULD restart v$ver -> v$latest: claude ${(j: :)${(@q-)flags}} --resume $sid"; return; fi

  # re-check right before acting: the agent may have started a turn meanwhile
  st=$(herdr agent list | jq -r --arg p "$pane" '.result.agents[] | select(.pane_id==$p) | .agent_status')
  [[ $st == idle || $st == done ]] || { echo "$pane SKIP became $st"; return; }
  herdr agent prompt "$pane" "/exit" >/dev/null 2>&1
  for _ in {1..30}; do sleep 1; kill -0 "$pid" 2>/dev/null || break; done
  if kill -0 "$pid" 2>/dev/null; then
    case $(exit_blocker "$pane") in
      scheduled) herdr pane send-keys "$pane" esc >/dev/null
                 echo "$pane SKIP has scheduled/background tasks (exit cancelled, session untouched)" ;;
      feedback)  echo "$pane NEEDS YOU: /exit asks about an unsent feedback draft (Enter reviews and sends, Esc discards it); left open" ;;
      *)         echo "$pane FAIL did not exit; check: herdr pane read $pane" ;;
    esac
    return
  fi
  sleep 1
  if ! herdr agent start "$name" --kind claude --pane "$pane" --timeout 120000 -- "${flags[@]}" --resume "$sid" >/dev/null 2>&1; then
    # a name clash with a live agent fails the start; retry under a pane-unique name
    herdr agent start "$(agent_name "$name-${pane//:/}")" --kind claude --pane "$pane" --timeout 120000 -- "${flags[@]}" --resume "$sid" >/dev/null 2>&1
  fi
  sleep 2
  np=$(pane_claude_pid "$pane")
  if [[ -n $np && -f $HOME/.claude/sessions/$np.json ]] &&
     [[ $(jq -r .sessionId "$HOME/.claude/sessions/$np.json") == "$sid" ]]; then
    echo "$pane OK v$ver -> v$(jq -r .version "$HOME/.claude/sessions/$np.json") sid=$sid rc=$(jq -r '.bridgeSessionId // "-"' "$HOME/.claude/sessions/$np.json")"
  else
    echo "$pane FAIL relaunch not verified; resume manually: claude ${(j: :)${(@q-)flags}} --resume $sid"
  fi
}

panes=("$@")
(( explicit )) || panes=("${(@f)$(herdr agent list | jq -r '.result.agents[] | select(.agent=="claude") | .pane_id')}")
echo "latest installed: $latest"
for p in "${panes[@]}"; do restart_one "$p"; done
