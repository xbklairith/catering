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

# pane_draft against fake screens (herdr stubbed; it answers only when asked for ANSI)
herdr() { [[ $* == *'--format ansi'* ]] && printf '%s\n' '● old turn' '❯ /remote-control' '────' "$SCREEN" '────'; }
for case in "❯ ||" "❯ half typed|half typed" '❯ Try "how do I log an error?"||' $'❯\xc2\xa0\xc2\xa0||' \
           $'❯ \e[0m\e[2mrun the tests again\e[0m\r||' $'❯ \e[0mhalf typed\e[0m\r|half typed'; do
  SCREEN=${case%%|*}; want=${${case#*|}%|}
  got=$(pane_draft x); eq "pane_draft [${(V)SCREEN:0:24}]" "$got|$?" "$want|0"
done
# unreadable pane or no input box must not look like an empty box
herdr() { return 2; }
got=$(pane_draft x); eq "pane_draft read fails" "$got|$?" "|1"
herdr() { printf '%s\n' 'some dialog' '> option'; }
got=$(pane_draft x); eq "pane_draft no prompt line" "$got|$?" "|1"

# exit_blocker names the /exit dialog holding a pane open; old conversation text that
# mentions a dialog must not count (stub honours --lines)
herdr() { local n=0; [[ $* == *--lines* ]] && n=${@[-1]}; (( n )) && print -r -- "$SCREEN" | tail -n $n || print -r -- "$SCREEN"; }
filler=$(printf 'conversation line %s\n' {1..40})
for case in "Background work is running"$'\n  daily ingest\n  Esc to cancel|scheduled' \
            "You have 1 unsent feedback draft. Enter to review and send, Esc to discard and exit|feedback" \
            "said: Background work is running"$'\n'"You have 1 unsent feedback draft. Esc to discard and exit|feedback" \
            "said: Background work is running"$'\n'"$filler"$'\n❯ |' \
            "❯ |"; do
  SCREEN=${case%|*}; eq "exit_blocker [${(V)SCREEN:0:24}]" "$(exit_blocker x)" "${case##*|}"
done
# a long screen must not break the match under pipefail (grep -q quitting early = SIGPIPE)
SCREEN=$(printf 'You have 1 unsent feedback draft\n%.0s' {1..60000})
eq "exit_blocker long screen" "$(exit_blocker x)" feedback
unfunction herdr

# pane_claude_pid / pane_claude_args across herdr output shapes (old argv0, newer argv only,
# a full path in argv[0]) and a pane without claude
herdr() { print -r -- "{\"result\":{\"process_info\":{\"foreground_processes\":[$PROC]}}}"; }
for case in '{"pid":7,"argv0":"claude","argv":["claude","-c"],"name":"2.1.306"}|7|-c' \
            '{"pid":7,"argv":["claude","-c"],"name":"claude"}|7|-c' \
            '{"pid":7,"argv":["/home/u/.local/bin/claude","-c"],"name":"2.1.306"}|7|-c' \
            '{"pid":8,"argv0":"zsh","argv":["zsh"],"name":"zsh"}||'; do
  PROC=${case%%|*}; rest=${case#*|}
  eq "pane_claude_pid [${PROC:0:40}]" "$(pane_claude_pid x)" "${rest%%|*}"
  eq "pane_claude_args [${PROC:0:40}]" "$(pane_claude_args x)" "${rest#*|}"
done
unfunction herdr

# strip_resume must work whatever the caller names its output array
kept=(); strip_resume kept --model opus --resume abc
eq "strip_resume into 'kept'" "${(j:|:)kept}" "--model|opus"

# split_session: session id out, everything else stays a flag
for case in "claude|--permission-mode=x --resume abc|abc|--permission-mode=x" \
            "claude|-r abc --add-dir '/a b'|abc|--add-dir,/a b" \
            "claude|--resume=abc -c --verbose|abc|--verbose" \
            "claude|--resume --verbose||--verbose" \
            "agy|--conversation=xyz|xyz|" \
            "agy|--conversation xyz --foo|xyz|--foo" \
            "codex|resume 123||resume,123"; do
  parts=("${(@s:|:)case}")
  sid=unset; flags=(unset)
  split_session sid flags "${parts[1]}" ${(Q)${(z)parts[2]}}
  eq "split_session ${parts[1]} [${parts[2]}]" "$sid|${(j:,:)flags}" "${parts[3]}|${parts[4]}"
done

# a snapshot row keeps flags with spaces, quotes and | intact
row=$(snapshot_row w1:p2 proj name claude /p/proj S1 --add-dir '/a b|c' "--msg=it's")
IFS='|' read -r pane label name kind cwd sid flags <<<"$row"
got=(${(Q)${(z)flags}})
eq "snapshot_row round trip" "$pane,$label,$name,$kind,$cwd,$sid,${(j:,:)got}" "w1:p2,proj,name,claude,/p/proj,S1,--add-dir,/a b|c,--msg=it's"

# restore_action: PANE SELF CWD_MATCH RUN_SID SAVED_SID RUN_FLAGS SAVED_FLAGS KIND
B=--permission-mode=bypassPermissions
for case in "-|w0|0||S1||$B|claude|manual" \
            "w1|w1|1||S1||$B|claude|self-start" \
            "w1|w1|1|S1|S1|$B|$B|claude|self-skip" \
            "w1|w1|1|S1|S1||$B|claude|self-flags" \
            "w1|w0|0||S1||$B|claude|new" \
            "w1|w0|1||S1||$B|claude|start" \
            "w1|w0|1|S9|S1|$B|$B|claude|other" \
            "w1|w0|1|S1|S1|$B|$B|claude|skip" \
            "w1|w0|1|S1|S1||$B|claude|reflag" \
            "w1|w0|1|C1|C1||--x|agy|differs"; do
  p=("${(@s:|:)case}")
  eq "restore_action -> ${p[9]} (${p[8]})" "$(restore_action "${(@)p[1,8]}")" "${p[9]}"
done

# snapshot_clobbers: a save must not overwrite flags with a flag-less herdr restore
prev=$(snapshot_row w1:p1 a a claude /a S1 $B; snapshot_row w1:p2 a b claude /a S2)
clob() { local got rc; got=$(snapshot_clobbers "$prev" "$2"); rc=$?; eq "snapshot_clobbers: $1" "$got|$rc" "$3"; }
clob "flags dropped"   "$(snapshot_row w1:p1 a a claude /a S1; snapshot_row w1:p2 a b claude /a S2)" "S1 (a)|0"
clob "flags kept"      "$(snapshot_row w1:p1 a a claude /a S1 $B)" "|1"
clob "session closed"  "$(snapshot_row w1:p2 a b claude /a S2)" "|1"

# end to end, dry runs against a fake herdr/claude and a fake home
t=$(mktemp -d); mkdir -p $t/bin $t/home/.claude/sessions $t/snap
cat > $t/bin/herdr <<'EOF'
#!/bin/zsh
case "$1 $2" in
  "agent list") print -r -- "$FAKE_AGENTS" ;;
  "workspace list") print -r -- '{"result":{"workspaces":[{"workspace_id":"w9","label":"proj"}]}}' ;;
  "pane process-info") print -r -- "{\"result\":{\"process_info\":{\"foreground_processes\":[$FAKE_PROC]}}}" ;;
  "pane get") print -r -- "{\"result\":{\"pane\":{\"cwd\":\"$FAKE_CWD\"}}}" ;;
  "pane read") print -r -- '❯ ' ;;
  *) exit 3 ;;
esac
EOF
printf '#!/bin/zsh\nprint "2.1.999 (Claude Code)"\n' > $t/bin/claude
chmod +x $t/bin/herdr $t/bin/claude
print -r -- '{"sessionId":"S1","version":"2.1.1","name":"proj"}' > $t/home/.claude/sessions/999999.json
fake() { env PATH=$t/bin:$PATH HOME=$t/home FLEET_SNAPSHOTS=$t/snap HERDR_PANE_ID=wZ:p9 FAKE_CWD=/p/proj \
  FAKE_AGENTS=${FAKE_AGENTS:-'{"result":{"agents":[{"pane_id":"w9:p9","workspace_id":"w9","name":"proj","agent":"claude","agent_status":"idle","cwd":"/p/proj"}]}}'} \
  FAKE_PROC='{"pid":999999,"argv":["claude","--resume","S1"]}' "$@" 2>&1; }
eq "restart-idle flags override" "$(fake $FLEET_HOME/scripts/restart-idle.sh --dry-run w9:p9 -- --model opus | tail -1)" \
   "w9:p9 WOULD restart v2.1.1 -> v2.1.999: claude --model opus --resume S1"
print -r -- "# test"$'\n'"w9:p9|proj|proj|claude|/p/proj|S1|$B" > $t/snap/fleet-20260101-000000.tsv
out=$(fake $FLEET_HOME/scripts/restore-fleet.sh --dry-run)
[[ $out == *"w9:p9 WOULD relaunch proj with its saved flags: claude $B --resume S1"* ]] && ok "restore-fleet reflags a flag-less resume" || bad "restore-fleet reflag: $out"
out=$(FAKE_AGENTS='{"result":{"agents":[]}}' fake $FLEET_HOME/scripts/save-fleet.sh); rc=$?
eq "save-fleet with no agents writes nothing" "$rc|$(print -l $t/snap/*(N) | wc -l | tr -d ' ')" "1|1"
out=$(fake $FLEET_HOME/scripts/save-fleet.sh); rc=$?
[[ $rc == 2 && $out == *"S1 (proj)"* ]] && ok "save-fleet refuses to drop saved flags" || bad "save-fleet clobber guard: rc=$rc $out"
rm -rf $t

# child_pids sees a child of this shell on both macOS and Linux
sleep 5 & kid=$!
[[ " $(child_pids $$ | tr '\n' ' ') " == *" $kid "* ]] && ok "child_pids ($FLEET_OS)" || bad "child_pids ($FLEET_OS)"
kill $kid 2>/dev/null

[[ -n $FLEET_PROJECTS && -d $FLEET_PROJECTS ]] && ok "FLEET_PROJECTS=$FLEET_PROJECTS" || bad "FLEET_PROJECTS"

echo; (( fails )) && { echo "$fails check(s) failed"; exit 1; } || echo "all checks passed"
