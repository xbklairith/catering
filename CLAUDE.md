# catering — agent fleet manager

This repo is not a code project to build. A Claude Code session started here manages the
other AI agent sessions on the machine: Claude Code sessions, herdr workspaces/panes, and
other agents (agy, codex, ...). Projects are the sibling directories of this repo unless
`FLEET_PROJECTS` says otherwise.

Use the `fleet` skill (`.claude/skills/fleet/SKILL.md`) for every fleet task: it maps
requests to the scripts in `scripts/`, holds the approval policy, and lists the gotchas.
Read `local/notes.md` when it exists. `local/` is gitignored and holds this machine's
knowledge (`notes.md`) and scripts (`scripts/`); `local.example/` shows the layout.

## Rules

- Closing a workspace/pane or killing a process changes someone else's work: confirm
  with the user first.
- Blocked agents: auto-approve prompts for read-only or safe actions (reading files,
  search, tests, lint, type check, build without deploy). Ask the user before approving
  anything that writes/deletes files, pushes, deploys, touches secrets or live databases,
  spends money, or answers a design/product question. Report every auto-approval.
- Reading panes, listing, and starting new agents need no confirmation.
- Sessions started with `--dangerously-skip-permissions` plus `/remote-control` can run
  anything from the remote link; tell the user when one is created.
- Nothing machine-specific (paths, project or session names, hosts) goes in committed
  files; it goes in `local/notes.md` or `local/scripts/`, listed in notes.md.

## Checks

Run `scripts/selftest.sh` after changing any script. It needs only zsh and jq.
