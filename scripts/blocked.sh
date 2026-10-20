#!/bin/zsh
# Show every blocked agent and the prompt it is waiting on (the bottom of its screen).
# Usage: blocked.sh [lines]   (default 25 screen lines per agent)
set -euo pipefail
source ${0:A:h}/lib.sh
require herdr jq

n=${1:-25}
panes=("${(@f)$(herdr agent list | jq -r '.result.agents[] | select(.agent_status=="blocked") | "\(.pane_id)\t\(.agent)\t\(.cwd)\t\(.terminal_title_stripped // "")"')}")
[[ -z ${panes[1]:-} ]] && { echo "no blocked agents"; exit 0; }
for row in "${panes[@]}"; do
  IFS=$'\t' read -r pane agent cwd title <<<"$row"
  echo "===== $pane  $agent  ${cwd#$FLEET_PROJECTS/}  $title ====="
  herdr pane read "$pane" | grep -v '^[[:space:]]*$' | tail -n "$n"
  echo
done
