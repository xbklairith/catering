#!/bin/zsh
# List background shells running under Claude Code sessions (Bash run_in_background /
# Monitor), oldest first, with the session they belong to. Long-lived
# `until grep ...; do sleep` loops whose target output already finished are dead waits:
# they block restart-idle.sh.
# Usage: stuck-loops.sh [min-age-minutes]   (default 30)
set -euo pipefail
source ${0:A:h}/lib.sh
require jq pgrep

min=${1:-30}
# macOS ps has no etimes: convert etime "[[dd-]hh:]mm:ss" to seconds
etime_secs() {
  local t=$1 d=0 h=0 m=0 sec=0
  [[ $t == *-* ]] && { d=${t%%-*}; t=${t#*-}; }
  local -a f; f=("${(@s/:/)t}")
  case ${#f} in 3) h=$f[1] m=$f[2] sec=$f[3] ;; 2) m=$f[1] sec=$f[2] ;; 1) sec=$f[1] ;; esac
  echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$sec ))
}

# one tab-separated row per shell, sorted by age, then printed as a two-line entry
for meta in ~/.claude/sessions/<->.json(N); do
  pid=${meta:t:r}
  kill -0 "$pid" 2>/dev/null || continue
  name=$(jq -r .name "$meta")
  for k in $(job_shells "$pid"); do
    et=$(ps -o etime= -p "$k" 2>/dev/null | tr -d ' '); [[ -n $et ]] || continue
    secs=$(etime_secs "$et")
    (( secs >= min * 60 )) || continue
    cmd=$(ps -o command= -p "$k")
    body=$(sed -nE "s/.*eval '(.*)' < \/dev\/null.*/\1/p" <<<"$cmd")
    out=$(grep -oE '/[^ ]*/tasks/[a-z0-9]+\.output' <<<"$cmd" | head -1 || true)
    last=""
    [[ -n $out ]] && last="waits on $out: $(tail -n 2 "$out" 2>/dev/null | tr '\n\t' '  ' | cut -c1-140)"
    printf '%s\t%s\t%s\t%s\t%s\n' "$secs" "$k" "$name" "${${body:-$cmd}:0:160}" "$last"
  done
done | sort -t$'\t' -k1,1rn | while IFS=$'\t' read -r secs k name body last; do
  printf '%6dm  pid=%-6s session=%-20s %s\n' $((secs / 60)) "$k" "$name" "$body"
  [[ -n $last ]] && echo "         $last"
done
true
