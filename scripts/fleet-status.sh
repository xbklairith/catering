#!/bin/zsh
# List every Claude Code agent in herdr panes: status, PID, version, session ID, name,
# remote-control bridge, and launch flags. Usage: fleet-status.sh
set -euo pipefail
source ${0:A:h}/lib.sh
require herdr jq claude

echo "latest installed: $(claude --version 2>/dev/null | awk '{print $1}')"
{
  echo "PANE|STATUS|PID|VERSION|SESSION_ID|NAME|REMOTE|ARGV"
  herdr agent list | jq -r '.result.agents[] | select(.agent=="claude") | "\(.pane_id) \(.agent_status)"' |
    while read -r pane st; do
      info=$(herdr pane process-info --pane "$pane" |
        jq -c '[.result.process_info.foreground_processes[] | select(.argv0=="claude")][0] // {}')
      pid=$(jq -r '.pid // "-"' <<<"$info")
      argv=$(jq -r '(.argv // []) | join(" ")' <<<"$info")
      meta=$HOME/.claude/sessions/$pid.json
      if [[ -f $meta ]]; then
        fields=$(jq -r '"\(.version)|\(.sessionId)|\(.name)|\(.bridgeSessionId // "-")"' "$meta")
      else
        fields="-|-|-|-"
      fi
      echo "$pane|$st|$pid|$fields|$argv"
    done
} | column -t -s'|'
