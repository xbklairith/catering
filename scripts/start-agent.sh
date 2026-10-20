#!/bin/zsh
# Open a project in a new herdr workspace and start an agent in it.
#
# Usage: start-agent.sh <project-dir> [--yolo] [--rc] [--label NAME] [--kind claude] [--force] [-- extra agent args]
#   --yolo   claude --dangerously-skip-permissions (anyone with an --rc link can run anything)
#   --rc     run /remote-control after start and print the claude.ai link
#   --label  workspace label and agent name (default: project folder name)
#   --force  create a new workspace even if one already has this directory
# Example: start-agent.sh ~/projects/myapp --yolo --rc
set -euo pipefail
source ${0:A:h}/lib.sh
require herdr jq

dir=${1:?usage: start-agent.sh <project-dir> [--yolo] [--rc] [--label NAME] [--kind KIND] [--force] [-- args]}
shift
dir=${dir:A}
[[ -d $dir ]] || { echo "no such directory: $dir" >&2; exit 1; }
yolo=0 rc=0 force=0 label=${dir:t} kind=claude
typeset -a extra
while (( $# )); do
  case $1 in
    --yolo) yolo=1 ;;
    --rc) rc=1 ;;
    --force) force=1 ;;
    --label) label=$2; shift ;;
    --kind) kind=$2; shift ;;
    --) shift; extra=("$@"); break ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done
if (( yolo )); then
  [[ $kind == claude ]] || { echo "--yolo only applies to --kind claude" >&2; exit 1; }
  extra=(--dangerously-skip-permissions "${extra[@]}")
fi

# a workspace whose agents already sit in this directory (avoids duplicate workspaces)
existing=$(herdr agent list | jq -r --arg d "$dir" '[.result.agents[] | select(.cwd==$d) | .workspace_id] | unique | join(" ")')
if [[ -n $existing ]] && (( ! force )); then
  echo "agents already run in $dir (workspace: $existing); pass --force for another workspace" >&2
  exit 1
fi

name=$(agent_name "$label")
pane=$(herdr workspace create --cwd "$dir" --label "$label" --no-focus | jq -r .result.root_pane.pane_id)
echo "workspace '$label' pane $pane"
if ! out=$(herdr agent start "$name" --kind "$kind" --pane "$pane" --timeout 120000 -- "${extra[@]}" 2>&1); then
  # name clash with a live agent: retry under a pane-unique name
  out=$(herdr agent start "$(agent_name "$name-${pane//:/}")" --kind "$kind" --pane "$pane" --timeout 120000 -- "${extra[@]}" 2>&1) ||
    { echo "agent start failed in pane $pane (workspace left open): $out" >&2; exit 1; }
fi
jq -r '"started \(.result.argv | join(" ")) -> \(.result.agent.agent_status)"' <<<"$out"

if (( rc )) && [[ $kind == claude ]]; then
  herdr agent prompt "$pane" "/remote-control" >/dev/null
  link=""
  for _ in {1..15}; do
    link=$(herdr pane read "$pane" | grep -oE 'https://claude\.ai/code/session_[A-Za-z0-9]+' | tail -1 || true)
    [[ -n $link ]] && break; sleep 1
  done
  echo "remote control: ${link:-not detected, check: herdr pane read $pane}"
fi
