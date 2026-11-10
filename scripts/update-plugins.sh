#!/bin/zsh
# Update Claude Code plugins. One install serves every session on the machine, but a running
# session keeps the plugin versions it started with until it restarts.
#   1. refresh every marketplace catalog
#   2. update each plugin installed at user scope. Plugins installed for one project, synced
#      from claude.ai or managed by an admin are listed and left alone.
#   3. --restart: if anything changed, restart-idle.sh on every Claude pane but this one
#      (same checks: busy sessions, unsent input, background jobs are skipped). This session
#      is restarted afterwards with restart-self.sh.
# When a marketplace wants to run a command to update a plugin, that plugin is reported as
# NEEDS YOU and left for a person to review; this script never confirms such a command.
# (Claude Code itself updates separately: claude update, then restart-idle.sh.)
#
# Usage: update-plugins.sh [--check] [--restart]
#   --check: refresh the catalogs and show what would update; installs nothing
set -uo pipefail
source ${0:A:h}/lib.sh
require claude jq

check=0 restart=0
for a; do
  case $a in
    --check)   check=1 ;;
    --restart) restart=1 ;;
    *) echo "usage: update-plugins.sh [--check] [--restart]" >&2; exit 1 ;;
  esac
done

claude plugin marketplace update </dev/null >/dev/null 2>&1 ||
  echo "warning: not every marketplace could be refreshed; using the catalogs on disk" >&2
markets=$(claude plugin marketplace list --json </dev/null 2>/dev/null) || markets='[]'

# newest version the marketplace's local catalog offers for NAME@MARKET, or nothing
catalog_version() {
  local name=${1%@*} market=${1#*@} dir cat v src
  dir=$(jq -r --arg m "$market" '.[] | select(.name==$m) | .installLocation // empty' <<<"$markets")
  cat=$dir/.claude-plugin/marketplace.json
  [[ -n $dir && -f $cat ]] || return 0
  v=$(jq -r --arg n "$name" '.plugins[] | select(.name==$n) | .version // empty' "$cat")
  if [[ -z $v ]]; then   # no version in the catalog entry: try the plugin's own manifest
    src=$(jq -r --arg n "$name" '.plugins[] | select(.name==$n) | .source | strings' "$cat")
    [[ -n $src && -f $dir/$src/.claude-plugin/plugin.json ]] && v=$(jq -r '.version // empty' "$dir/$src/.claude-plugin/plugin.json")
  fi
  print -r -- "$v"
}

changed=0
while IFS=$'\t' read -r id ver scope; do
  if [[ $scope != user ]]; then echo "$id SKIP $scope install ($ver), not updated here"; continue; fi
  if (( check )); then
    new=$(catalog_version "$id")
    if [[ -z $new ]]; then echo "$id ? $ver installed; the catalog shows no version"
    elif [[ $new != "$ver" ]]; then echo "$id WOULD update $ver -> $new"
    else echo "$id up to date ($ver)"; fi
    continue
  fi
  out=$(claude plugin update "$id" --scope user --json </dev/null 2>/dev/null)
  json=(${(M)${(f)out}:#\{*}); res=${json[-1]:-}   # the JSON result line
  if [[ -n $(jq -r '.shownCommand // empty' <<<"$res" 2>/dev/null) ]]; then
    echo "$id NEEDS YOU its marketplace wants to run a command to update it; review it with: claude plugin update $id"
  elif [[ $(jq -r '.outcome // empty' <<<"$res" 2>/dev/null) == ok ]]; then
    old=$(jq -r '.oldVersion // "?"' <<<"$res"); new=$(jq -r '.newVersion // "?"' <<<"$res")
    if [[ $old == "$new" ]]; then echo "$id up to date ($new)"
    else echo "$id OK $old -> $new"; changed=1; fi
  else
    msg=$(jq -r '.message // empty' <<<"$res" 2>/dev/null); echo "$id FAIL ${msg:-${out//$'\n'/ }}"
  fi
done < <(claude plugin list --json </dev/null | jq -r '.[] | [.id, (.version // "?"), (.scope // "?")] | @tsv')

(( check )) && exit 0
(( changed )) || { echo "nothing changed; no restart needed"; exit 0; }
if (( ! restart )); then
  echo "running sessions keep the old versions until they restart: update-plugins.sh --restart, or restart-idle.sh PANE..."
  exit 0
fi
require herdr
self=${HERDR_PANE_ID:-}
panes=(${(f)"$(herdr agent list | jq -r '.result.agents[] | select(.agent=="claude") | .pane_id')"})
panes=(${panes:#$self})
(( ${#panes} )) && ${0:A:h}/restart-idle.sh "${panes[@]}"
[[ -n $self && -n $(pane_claude_pid "$self" 2>/dev/null) ]] &&
  echo "$self (this session) still runs the old versions: restart it with restart-self.sh"
exit 0
