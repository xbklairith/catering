#!/bin/zsh
# Link the fleet skill into ~/.claude/skills so any Claude Code session can use it, and
# check dependencies. Safe to re-run.
set -euo pipefail

repo=${0:A:h}
src=$repo/.claude/skills/fleet
dest=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/fleet

for c in zsh jq pgrep ps; do command -v $c >/dev/null || { echo "missing: $c" >&2; exit 1; }; done
for c in herdr claude; do command -v $c >/dev/null || echo "warning: $c not on PATH (needed at run time)"; done

mkdir -p "${dest:h}"
if [[ -L $dest ]]; then
  ln -sfn "$src" "$dest"
elif [[ -e $dest ]]; then
  echo "$dest exists and is not a link; move it away first" >&2; exit 1
else
  ln -s "$src" "$dest"
fi
echo "linked $dest -> $src"
if [[ ! -d $repo/local ]]; then
  cp -R "$repo/local.example" "$repo/local"
  echo "created $repo/local from local.example (gitignored): edit local/notes.md"
fi
