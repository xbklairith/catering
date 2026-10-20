#!/bin/zsh
# Catch short-lived CPU-heavy `find` processes and print who launched them. Inside Claude
# Code shells `find` runs as the bundled `bfs`, so both names are matched.
# Usage: find-watch.sh [seconds]   (default 300; 0 = forever)
# Typical culprits: agents running `find ~` or `find <projects dir>` across huge trees
# (vendored corpora, node_modules, caches). Prefer rg/fd, which honour .gitignore.
set -uo pipefail

dur=${1:-300}
end=$(( SECONDS + dur ))
typeset -A seen
while (( dur == 0 || SECONDS < end )); do
  ps -Ao pid=,ppid=,%cpu=,command= | awk '$4 ~ /(^|\/)(find|bfs)$/' | while read -r pid ppid cpu cmd; do
    [[ -n ${seen[$pid]:-} ]] && continue
    seen[$pid]=1
    parent=$(ps -o command= -p "$ppid" 2>/dev/null | cut -c1-120)
    owner=""; p=$ppid
    for _ in {1..6}; do                      # walk up to the owning claude session, if any
      [[ -f ~/.claude/sessions/$p.json ]] && { owner=$(jq -r .name ~/.claude/sessions/$p.json); break; }
      p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' '); [[ -z $p || $p == 1 ]] && break
    done
    echo "$(date +%T) find pid=$pid cpu=$cpu: ${cmd:0:160}"
    echo "         parent: $parent${owner:+  (claude session: $owner)}"
  done
  sleep 1
done
