#!/bin/zsh
# Restart the Claude Code session in the calling herdr pane (the manager itself) onto the
# latest version, resuming the same session ID. Runs detached: it waits for the session to
# go idle (the current turn to end), sends /exit, then relaunches with the same flags.
# Aborts without exiting if the session never goes idle within 20 min or has unsent input.
#
# Usage (from inside the session): scripts/restart-self.sh [extra claude flags...]
#   e.g. scripts/restart-self.sh --add-dir "$(git rev-parse --show-toplevel)"
#   extra flags already present in the current argv are not added twice
# Log: <repo>/logs/restart-self-<timestamp>.log
set -uo pipefail
source ${0:A:h}/lib.sh
require herdr jq claude

pane=${HERDR_PANE_ID:?not inside a herdr pane}
dir=${0:A:h}
log=${dir:h}/logs/restart-self-$(date +%Y%m%d-%H%M%S).log
mkdir -p "${log:h}"

pid=$(pane_claude_pid "$pane")
meta=$HOME/.claude/sessions/$pid.json
[[ -n $pid && -f $meta ]] || { echo "no claude session metadata for pane $pane" >&2; exit 1; }
sid=$(jq -r .sessionId "$meta")
name=$(agent_name "$(jq -r .name "$meta")")

local -a args flags
args=("${(@f)$(pane_claude_args "$pane")}"); [[ -z ${args[1]:-} ]] && args=()
strip_resume flags "${args[@]}"
# append caller extras unless the same "flag value" sequence is already there
if (( $# )) && [[ " ${(j: :)flags} " != *" $* "* ]]; then flags+=("$@"); fi

# everything the detached helper needs, quoted for re-parsing by zsh -c
helper=$(cat <<EOF
source ${(q)dir}/lib.sh
pane=${(q)pane} pid=$pid meta=${(q)meta} sid=$sid name=${(q)name}
flags=(${(@q)flags})
echo "\$(date) waiting for \$pid (\$sid) to go idle"
st=""
for i in {1..600}; do
  st=\$(jq -r .status "\$meta" 2>/dev/null)
  [[ \$st == idle ]] && break; sleep 2
done
[[ \$st == idle ]] || { echo "\$(date) ABORT: session never went idle (last status: \$st)"; exit 1; }
sleep 3
draft=\$(pane_draft "\$pane") || { echo "\$(date) ABORT: input box not readable"; exit 1; }
[[ -n \$draft ]] && { echo "\$(date) ABORT: unsent input in the box: \$draft"; exit 1; }
herdr agent prompt "\$pane" /exit
for i in {1..60}; do kill -0 \$pid 2>/dev/null || break; sleep 1; done
if kill -0 \$pid 2>/dev/null; then
  case \$(exit_blocker "\$pane") in
    scheduled) herdr pane send-keys "\$pane" esc; echo "\$(date) ABORT: scheduled tasks, exit cancelled" ;;
    feedback)  echo "\$(date) ABORT: unsent feedback draft dialog left open for the user (Esc would discard it)" ;;
    *)         echo "\$(date) ABORT: session did not exit" ;;
  esac
  exit 1
fi
sleep 1
herdr agent start "\$name" --kind claude --pane "\$pane" --timeout 120000 -- "\${flags[@]}" --resume \$sid ||
  herdr agent start "\$(agent_name "\$name-\${pane//:/}")" --kind claude --pane "\$pane" --timeout 120000 -- "\${flags[@]}" --resume \$sid
echo "\$(date) relaunched: claude \${(j: :)\${(@q-)flags}} --resume \$sid"
EOF
)

nohup zsh -c "$helper" >"$log" 2>&1 &!

echo "helper started; log: $log"
echo "will relaunch: claude ${(j: :)${(@q-)flags}} --resume $sid"
