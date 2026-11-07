#!/bin/zsh
# Snapshot the fleet so restore-fleet.sh can bring it back after a reboot or a herdr server
# restart: every agent in a herdr pane, and every Claude session running outside herdr,
# with its session id and the launch flags it needs. (herdr restores layout and session ids
# by itself, but relaunches Claude as a bare `claude --resume <id>`, dropping flags such as
# the permission mode.)
#
# Usage: save-fleet.sh [--force] [--quiet]
# Writes $FLEET_SNAPSHOTS/fleet-<time>.tsv (default local/snapshots/, keeps the newest 20).
# Writes nothing when herdr is unreachable or shows no agents (exit 1), when nothing changed,
# or (exit 2; --force saves anyway) when
#   - sessions saved with flags now run without them, which is what herdr's own restore
#     leaves behind until restore-fleet.sh runs, or
#   - the machine rebooted after the newest snapshot and restore-fleet.sh has not run since.
set -uo pipefail
source ${0:A:h}/lib.sh
require herdr jq
zmodload zsh/datetime
zmodload -F zsh/stat b:zstat

force=0 quiet=0
for a; do
  case $a in
    --force) force=1 ;;
    --quiet) quiet=1 ;;
    *) echo "usage: save-fleet.sh [--force] [--quiet]" >&2; exit 1 ;;
  esac
done
say() { (( quiet )) || print -r -- "$@"; }

agents=$(herdr agent list 2>/dev/null) || { echo "herdr is not reachable; nothing saved" >&2; exit 1; }
labels=$(herdr workspace list 2>/dev/null | jq -c '[.result.workspaces[] | {key: (.workspace_id // .id), value: (.label // .name // "")}] | from_entries' 2>/dev/null) || labels='{}'

typeset -a rows pane_pids av flags
while IFS='|' read -r pane ws name kind cwd; do
  label=$(jq -r --arg w "$ws" '.[$w] // $w' <<<"$labels")
  [[ -n $name ]] || name=$(agent_name "$label-$kind")
  proc=$(herdr pane process-info --pane "$pane" | jq -c --arg k "$kind" '[.result.process_info.foreground_processes[] |
           select(((.argv0 // .argv[0] // "") | split("/") | last) == $k)][0] // {}')
  av=("${(@f)$(jq -r '.argv // [] | .[1:][]' <<<"$proc")}"); av=(${av:#})
  pid=$(jq -r '.pid // empty' <<<"$proc")
  split_session sid flags "$kind" "${av[@]}"
  if [[ -n $pid ]]; then
    pane_pids+=($pid)
    meta=$HOME/.claude/sessions/$pid.json
    [[ $kind == claude && -f $meta ]] && sid=$(jq -r '.sessionId // empty' "$meta")
  fi
  rows+=("$(snapshot_row "$pane" "$label" "$name" "$kind" "$cwd" "$sid" "${flags[@]}")")
done < <(jq -r '.result.agents[] | [.pane_id, .workspace_id, .name, .agent, .cwd] | join("|")' <<<"$agents")

# Claude sessions a person started in a terminal outside herdr (not headless/SDK runs)
for meta in $HOME/.claude/sessions/*.json(N); do
  pid=${meta:t:r}
  (( ${pane_pids[(Ie)$pid]} )) && continue
  kill -0 "$pid" 2>/dev/null || continue
  av=(${(z)"$(ps -o command= -p "$pid" 2>/dev/null)"})
  [[ ${av[1]:-} == claude ]] || continue
  (( ${av[(Ie)-p]} || ${av[(Ie)--print]} )) && continue
  split_session sid flags claude "${av[@]:1}"
  rows+=("$(snapshot_row - - "$(jq -r '.name // "-"' "$meta")" claude "$(jq -r '.cwd' "$meta")" \
            "$(jq -r '.sessionId' "$meta")" "${flags[@]}")")
done

(( ${#rows} )) || { echo "herdr shows no agents; nothing saved" >&2; exit 1; }
new=${(F)rows}
prev=$(snapshot_latest)
if [[ -n $prev ]]; then
  old=$(grep -v '^#' "$prev")
  [[ $old == "$new" ]] && { say "unchanged since ${prev:t}"; exit 0; }
  stamp=""; [[ -f $FLEET_RESTORED ]] && stamp=$(zstat +mtime "$FLEET_RESTORED")
  if (( ! force )) && rebooted_unrestored "$(zstat +mtime "$prev")" "$(boot_epoch)" "$stamp"; then
    echo "not saved: this machine rebooted after the newest snapshot (${prev:t}) and" >&2
    echo "restore-fleet.sh has not run since, so the fleet may be only partly back." >&2
    echo "Run restore-fleet.sh first, or save-fleet.sh --force to save the fleet as it is now." >&2
    exit 2
  fi
  if (( ! force )) && lost=$(snapshot_clobbers "$old" "$new"); then
    echo "not saved: these sessions were saved with launch flags and now run without them," >&2
    echo "as herdr's own restore leaves them. Run restore-fleet.sh first, or save-fleet.sh --force:" >&2
    print -r -- "$lost" >&2
    exit 2
  fi
fi

mkdir -p "$FLEET_SNAPSHOTS"
file=$FLEET_SNAPSHOTS/fleet-$(strftime %Y%m%d-%H%M%S $EPOCHSECONDS).tsv
{
  print -r -- "# fleet snapshot $(strftime '%Y-%m-%d %H:%M:%S' $EPOCHSECONDS). pane|workspace|name|kind|cwd|session|flags; pane - = outside herdr"
  print -r -- "$new"
} > "$file"
old_files=($FLEET_SNAPSHOTS/fleet-*.tsv(Nom))
(( ${#old_files} > 20 )) && rm -f -- "${old_files[@]:20}"
say "saved ${#rows} agent(s) to $file"
