#!/bin/zsh
# Example machine-specific script. Scripts in local/scripts/ can use the shared helpers:
# FLEET_HOME, FLEET_PROJECTS, agent_name, pane_claude_pid, job_shells, pane_draft, ...
# Describe each local script in local/notes.md so the manager knows when to use it.
set -euo pipefail
source ${0:A:h:h:h}/scripts/lib.sh
require herdr jq

echo "fleet repo: $FLEET_HOME"
echo "projects:   $FLEET_PROJECTS"
herdr workspace list | jq -r '.result.workspaces[] | "\(.label)\t\(.agent_status)"'
