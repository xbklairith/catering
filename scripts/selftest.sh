#!/bin/zsh
# Syntax and unit checks for the fleet scripts (and local/scripts). Needs zsh and jq only:
# no herdr, no claude, nothing is started or stopped. Usage: selftest.sh
set -uo pipefail
source ${0:A:h}/lib.sh
require jq

fails=0
ok()   { echo "ok    $1"; }
bad()  { echo "FAIL  $1"; (( fails++ )); }
eq()   { [[ $2 == "$3" ]] && ok "$1" || bad "$1: got [$2] want [$3]"; }

for f in $FLEET_HOME/scripts/*.sh $FLEET_HOME/install.sh $FLEET_HOME/local.example/scripts/*(N.) $FLEET_LOCAL/scripts/*(N.); do
  zsh -n "$f" 2>/dev/null && ok "syntax ${f#$FLEET_HOME/}" || bad "syntax ${f#$FLEET_HOME/}"
done

eq "agent_name mixed case"   "$(agent_name 'Land lord')"    land-lord
eq "agent_name camel"        "$(agent_name TableManager)"   tablemanager
eq "agent_name leading digit" "$(agent_name 9lives)"        a-9lives
long=$(printf "x%.0s" {1..40})
eq "agent_name max 32"       "${#$(agent_name $long)}" 32

local -a out
strip_resume out --permission-mode=bypassPermissions --resume
eq "strip bare --resume"     "${(j:|:)out}" --permission-mode=bypassPermissions
strip_resume out --resume abc-123 --append-system-prompt "be brief" -c --model opus
eq "strip id, keep spaced arg" "${(j:|:)out}" "--append-system-prompt|be brief|--model|opus"
strip_resume out -r 1f2e --resume=xyz --continue --verbose
eq "strip -r/--resume=/--continue" "${(j:|:)out}" --verbose

# pane_draft against fake screens (herdr stubbed)
herdr() { printf '%s\n' '● old turn' '❯ /remote-control' '────' "$SCREEN" '────'; }
for case in "❯ ||" "❯ half typed|half typed" '❯ Try "how do I log an error?"||' $'❯\xc2\xa0\xc2\xa0||'; do
  SCREEN=${case%%|*}; want=${${case#*|}%|}
  eq "pane_draft [${SCREEN:0:20}]" "$(pane_draft x)" "$want"
done
unfunction herdr

# child_pids sees a child of this shell on both macOS and Linux
sleep 5 & kid=$!
[[ " $(child_pids $$ | tr '\n' ' ') " == *" $kid "* ]] && ok "child_pids ($FLEET_OS)" || bad "child_pids ($FLEET_OS)"
kill $kid 2>/dev/null

[[ -n $FLEET_PROJECTS && -d $FLEET_PROJECTS ]] && ok "FLEET_PROJECTS=$FLEET_PROJECTS" || bad "FLEET_PROJECTS"

echo; (( fails )) && { echo "$fails check(s) failed"; exit 1; } || echo "all checks passed"
