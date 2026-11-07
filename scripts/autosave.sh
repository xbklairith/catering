#!/bin/zsh
# Keep a recent fleet snapshot without having to remember: save-fleet.sh runs every 15
# minutes on its own, so restore-fleet.sh has something to work from after a crash or an
# unplanned reboot. save-fleet.sh's guards still apply: after a reboot nothing is saved
# until restore-fleet.sh has run.
#   macOS: a launchd agent, ~/Library/LaunchAgents/catering.autosave.plist
#   Linux: one crontab line marked "# catering-autosave"; the rest of the crontab is kept
# FLEET_SCHEDULER=cron|launchd overrides the choice. (On macOS, writing a crontab can wait
# on a permission dialog, which is why launchd is the default there.)
#
# Usage: autosave.sh install | remove | status
#        autosave.sh run   (what the scheduler calls: save-fleet.sh, outcome logged to
#                           $FLEET_SNAPSHOTS/autosave.log unless nothing changed)
set -uo pipefail
source ${0:A:h}/lib.sh
zmodload zsh/datetime

self=${0:A}                              # (inside a function $0 is its name)
log=$FLEET_SNAPSHOTS/autosave.log
every=900                                # seconds
mark='# catering-autosave'
label=catering.autosave
plist=$HOME/Library/LaunchAgents/$label.plist
scheduler=${FLEET_SCHEDULER:-}
[[ -n $scheduler ]] || { [[ $FLEET_OS == Darwin ]] && scheduler=launchd || scheduler=cron; }
[[ $scheduler == (cron|launchd) ]] || { echo "FLEET_SCHEDULER must be cron or launchd" >&2; exit 1; }

# the scheduler starts jobs with a bare environment: give them the tools the scripts need
job_path() {
  local -U dirs; dirs=(${commands[herdr]:h} ${commands[jq]:h} ${commands[zsh]:h} /usr/bin /bin /usr/sbin /sbin)
  print -r -- ${(j.:.)dirs}
}

# --- cron ---
current() { crontab -l 2>/dev/null; return 0; }
ours()    { print -r -- ${(M)${(f)"$(current)"}:#*$mark}; }
others()  { local l; for l in "${(@f)$(current)}"; do [[ -n $l && $l != *$mark ]] && print -r -- "$l"; done; return 0; }

cron_install() {
  require crontab
  [[ $self$FLEET_SNAPSHOTS == *%* ]] && { echo "a crontab line can't hold a path with %" >&2; exit 1; }
  local line="*/$(( every / 60 )) * * * * PATH=${(q-)$(job_path)} FLEET_SNAPSHOTS=${(q-)FLEET_SNAPSHOTS} ${(q-)self} run $mark"
  local keep=$(others)   # read before writing: never pipe crontab -l into crontab -
  { [[ -n $keep ]] && print -r -- "$keep"; print -r -- "$line"; } | crontab - || { echo "could not write the crontab" >&2; exit 1; }
  [[ $(ours) == "$line" ]] || { echo "the crontab did not take the line; check: crontab -l" >&2; exit 1; }
  echo "installed: $line"
}
cron_remove() {
  require crontab
  [[ -n $(ours) ]] || { echo "not installed"; return; }
  local rest=$(others)
  if [[ -n $rest ]]; then print -r -- "$rest" | crontab -; else crontab -r; fi
  [[ -z $(ours) ]] && echo "removed" || { echo "could not remove the line; check: crontab -l" >&2; exit 1; }
}
cron_status() { local l=$(ours); [[ -n $l ]] && echo "installed: $l" || echo "not installed"; }

# --- launchd ---
xml() { local s=${1//&/&amp;}; s=${s//</&lt;}; print -r -- ${s//>/&gt;}; }
domain=gui/$UID

launchd_install() {
  require launchctl
  mkdir -p ${plist:h}
  cat > $plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$(xml $self)</string><string>run</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(xml "$(job_path)")</string>
    <key>FLEET_SNAPSHOTS</key><string>$(xml $FLEET_SNAPSHOTS)</string>
  </dict>
  <key>StartInterval</key><integer>$every</integer>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
EOF
  launchctl bootout $domain/$label 2>/dev/null
  local try
  for try in 1 2 3; do   # a bootstrap right after a bootout can fail while launchd catches up
    launchctl bootstrap $domain $plist 2>/dev/null && break
    sleep 1
  done
  launchctl print $domain/$label >/dev/null 2>&1 || { echo "launchd did not load $plist" >&2; exit 1; }
  echo "installed: launchd agent $label, every $(( every / 60 )) minutes ($plist)"
}
launchd_remove() {
  require launchctl
  [[ -f $plist ]] || launchctl print $domain/$label >/dev/null 2>&1 || { echo "not installed"; return; }
  launchctl bootout $domain/$label 2>/dev/null
  rm -f $plist
  echo "removed"
}
launchd_status() {
  if launchctl print $domain/$label >/dev/null 2>&1; then echo "installed: launchd agent $label ($plist)"
  elif [[ -f $plist ]]; then echo "not installed: $plist exists but is not loaded (run install again)"
  else echo "not installed"; fi
}

case ${1:-} in
  install) require herdr jq; ${scheduler}_install ;;
  remove)  ${scheduler}_remove ;;
  status)
    ${scheduler}_status
    latest=$(snapshot_latest)
    [[ -n $latest ]] && echo "newest snapshot: $latest"
    [[ -f $log ]] && { echo "last log lines ($log):"; tail -n 5 "$log"; }
    exit 0 ;;
  run)
    mkdir -p "$FLEET_SNAPSHOTS"
    out=$(${self:h}/save-fleet.sh 2>&1); rc=$?
    [[ $rc == 0 && $out == unchanged* ]] && exit 0
    print -r -- "$(strftime '%Y-%m-%d %H:%M' $EPOCHSECONDS) rc=$rc ${out//$'\n'/ / }" >> "$log"
    if (( $(wc -l < "$log") > 500 )); then tail -n 300 "$log" > "$log.tmp" && mv -f "$log.tmp" "$log"; fi ;;
  *)
    echo "usage: autosave.sh install | remove | status | run" >&2; exit 1 ;;
esac
